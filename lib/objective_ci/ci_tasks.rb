require 'bundler/setup'
require 'nokogiri'

module ObjectiveCi
    class CiTasks

    attr_accessor :exclusions

    LINT_DESTINATION = "lint.html"
    DUPLICATION_DESTINATION = "duplication.xml"
    LINE_COUNT_DESTINATION = "line-count.sc"

    def initialize
      @exclusions = ["vendor"]
      if using_pods?
        @exclusions << "Pods"
        `bundle exec pod install`
      end
    end

    def build(opts={})
      lint(opts)
      lines_of_code(opts)
      test_suite(opts)
      duplicate_code_detection(opts)
    end

    def lint(opts={})
      requires_at_least_one_option(opts, :workspace, :project)
      requires_options(opts, :scheme)
      opts[:configuration] ||= "Release"
      opts[:output] ||= "./lint.html"
      opts[:destination] ||= "'platform=iOS Simulator,name=iPad 2,OS=9.2'"
      opts[:sdk] ||= "iphonesimulator"

      sliced_opts = opts.select { |k, v| [:scheme, :workspace, :project, :destination, :configuration, :sdk].include?(k) }
      xcodebuild_opts_string = sliced_opts.reduce("") { |str, (k, v)| str += " -#{k} #{v}" }

      call_binary("xcodebuild", xcodebuild_opts_string, "| xcpretty -r json-compilation-database", opts)
      system("mv build/reports/compilation_db.json ./compile_commands.json")
      ocjcd_opts_string = "-e \"Pods\" -- -report-type html -o #{opts[:output]} -rc LONG_LINE=150"
      call_binary("oclint-json-compilation-database", ocjcd_opts_string, "", opts)
    end

    def test_suite(opts={})
      requires_at_least_one_option(opts, :workspace, :project)
      requires_options(opts ,:scheme)
      if !opts[:xcodebuild_override] && xcode_version < 5.0
        puts_red "WARNING: Xcode version #{xcode_version} is less than 5.0, and tests will likely not run"
      end

      opts[:destination] ||= "'platform=iOS Simulator,name=iPad 2,OS=9.2'"
      opts[:sdk] ||= "iphonesimulator"
      opts[:configuration] ||= "Release"

      sliced_opts = opts.select { |k, v| [:scheme, :workspace, :project, :destination, :configuration, :sdk].include?(k) }
      xcodebuild_opts_string = sliced_opts.reduce("") { |str, (k, v)| str += " -#{k} #{v}" }

      xcodebuild_opts_string += " test"
      call_binary("xcodebuild", xcodebuild_opts_string, " | tee xcodebuild.log | bundle exec xcpretty --color --report html", opts)
    end

    def lines_of_code(opts={})
      opts[:output] ||= "./#{LINE_COUNT_DESTINATION}"
      call_binary("sloccount",
                  "--duplicates --wide --details .",
                  "| grep -v #{exclusion_options_list("-e")} > #{opts[:output]}",
                  opts)
    end

    def duplicate_code_detection(opts={})
      opts[:minimum_tokens] ||= 100
      # Use `sed` to change paths like `/some/code/./path.m` to `/some/code/path.m`, or else the Violations plugin in Jenkins
      # doesn't work correctly.
      opts[:output] ||= "./#{DUPLICATION_DESTINATION}"
      call_binary("pmd-cpd-objc",
                  "--minimum-tokens #{opts[:minimum_tokens]}",
                  "| LC_CTYPE=C LANG=C sed 's/\\/\\.\\//\\//' > #{opts[:output]}",
                  opts)
      pmd_exclude(opts[:output])
      pmd_patch(opts[:output])
    end

    def code_coverage(opts={})
      requires_options(opts, :scheme, :project)
      opts[:output] ||= "./coverage"
      # Use slather to compute code coverage here instead of Rakefile
      call_binary("slather", "coverage --input-format profdata --html --output-directory #{opts[:output]} --scheme #{opts[:scheme]} #{opts[:project]}", "", opts)
    end

    def exclusion_options_list(option_flag)
      if exclusions.empty?
        ''
      else
        wrapped_exclusions = exclusions.map { |e| "\"#{e}\"" }
        "#{option_flag} #{wrapped_exclusions.join(" #{option_flag} ")}"
      end
    end
    private :exclusion_options_list

    def using_pods?
      File.exists?("Podfile") || File.exists?("podfile")
    end
    private :using_pods?

    def call_binary(binary, cl_options, tail, opts={})
      extra_options = opts["#{binary}_options".to_sym]
      override_options = opts["#{binary}_override".to_sym]
      cl_options = override_options ? extra_options : "#{cl_options} #{extra_options}"
      command = "#{binary} #{cl_options} #{tail}"
      command.prepend("bundle exec ") unless binary == "xcodebuild"
      puts command
      system("#{command}")
    end
    private :call_binary

    def requires_options(opts, *keys)
      keys.each do |k|
        raise "option #{k} is required." unless opts.has_key?(k)
      end
    end
    private :requires_options

    def requires_at_least_one_option(opts, *keys)
      if (opts.keys && keys).empty?
        raise "at least one of the options #{keys.join(", ")} is required"
      end
    end
    private :requires_at_least_one_option

    def pmd_exclude(destination)
      # Unfortunately, pmd doesn't seem to provide any nice out-of-the-box way for excluding files from the results.
      absolute_exclusions = exclusions.map { |e| "#{Dir.pwd}/#{e}/" }
      regex_exclusion = Regexp.new("(#{absolute_exclusions.join("|")})")
      output = Nokogiri::XML(File.open(destination))
      output.xpath("//duplication").each do |duplication_node|
        if duplication_node.xpath("file").all? { |n| n["path"] =~ regex_exclusion }
          duplication_node.remove
        end
      end
      File.open(destination, 'w') { |file| file.write(output.to_s) }
    end
    private :pmd_exclude

    def pmd_patch(destination)
      # Make sure encoding is UTF-8, or else Jenkins DRY plugin will fail to parse.
      new_xml = Nokogiri::XML.parse(File.open(destination).read, nil, "UTF-8")
      File.open(destination, 'w') { |file| file.write(new_xml.to_s) }
    end
    private :pmd_patch

    def xcode_version
      matches = `xcodebuild -version`.match(/^Xcode ([0-9]+\.[0-9]+)/)
      matches ? matches[1].to_f : 0.0
    end
    private :xcode_version

    def puts_red(str)
      puts "\e[31m#{str}\e[0m"
    end
    private :puts_red

  end
end
