# frozen_string_literal: true

require_relative "../insta"
require_relative "ansi"
require_relative "syntax_highlight"

module Insta
  class CLI
    include ANSI

    COMMANDS = ["review", "accept", "reject", "pending", "status", "clean", "help"].freeze
    MIN_GAP = 8 #: Integer

    #: (Array[String]) -> void
    def initialize(args)
      @command = args.first || "help"
      @args = args.drop(1)
    end

    #: () -> void
    def run
      case @command
      when "review" then review
      when "accept" then accept
      when "reject" then reject
      when "pending" then pending_list
      when "status" then status
      when "clean" then clean
      when "help", "--help", "-h" then help
      when "--version", "-v" then version
      else
        warn header
        warn
        warn "#{dim("Invalid command:")} #{red(@command)}"
        warn
        warn "Run #{cyan("insta help")} for usage information."
        exit 1
      end
    end

    private

    def pluralize(count, singular, plural = "#{singular}s") = count == 1 ? singular : plural

    #: () -> void
    def review
      pending_files = find_pending_files
      inline_entries = Inline::PendingStore.load

      if pending_files.empty? && inline_entries.empty?
        puts "#{green("✓")} No pending snapshots to review."
        return
      end

      @pending_locations = PendingLocations.load
      @accepted_count = 0
      @rejected_count = 0

      total = pending_files.length + inline_entries.length
      puts "#{yellow("●")} Found #{bold(total.to_s)} pending #{pluralize(total, "snapshot")} to review.\n\n"

      @quit = false
      review_files(pending_files) unless pending_files.empty?
      review_inline_entries(inline_entries) unless @quit || inline_entries.empty?

      print_review_summary
    end

    #: (Array[String]) -> void
    def review_files(files)
      accept_all = false
      reject_all = false

      files.each do |pending_file|
        if accept_all
          accept_file(pending_file)
          next
        end

        if reject_all
          reject_file(pending_file)
          next
        end

        result = review_single_file(pending_file)

        case result
        when :accept_all
          accept_all = true
        when :reject_all
          reject_all = true
        when :quit
          puts "Quit."
          @quit = true
          break
        end
      end
    end

    #: (String) -> Symbol
    def review_single_file(pending_file)
      original = pending_file.sub(/\.new\z/, "")
      snap_name = File.basename(original)

      puts bold("─── #{snap_name} ───")
      display_source_context(pending_file)
      display_snapshot_paths(original, pending_file)
      puts
      display_diff(original, pending_file)

      action = prompt_review_action
      process_review_action(action, pending_file)
    end

    #: () -> Symbol
    def prompt_review_action
      puts

      loop do
        print review_prompt_line

        response = $stdin.gets&.strip || "s"

        case response
        when "h"
          print_review_help
        when "a"
          break :accept
        when "r"
          break :reject
        when "A"
          break :accept_all
        when "R"
          break :reject_all
        when "q"
          break :quit
        else
          break :skip
        end
      end
    end

    #: () -> String
    def review_prompt_line
      "  #{bold(green("[a]ccept"))}  #{bold(red("[r]eject"))}  #{dim("[s]kip")}  " \
        "#{bold(green("[A]ccept all"))}  #{bold(red("[R]eject all"))}  " \
        "#{dim("[q]uit")}  #{dim("[h]elp")}: "
    end

    #: (String) -> void
    def display_source_context(pending_file)
      locations = @pending_locations || {}
      caller_location = locations[pending_file]

      if caller_location
        display_caller_context(caller_location)
      else
        snapshot = Snapshot.parse(File.read(pending_file))
        source = snapshot.source
        puts "  #{dim("Source:")} #{cyan(source)}" if source

        test_file = find_test_file(pending_file)
        return unless test_file

        method_name = source&.split("#")&.last
        lineno = method_name ? find_test_line(test_file, method_name) : nil
        location = lineno ? "#{test_file}:#{lineno}" : test_file

        puts "  #{dim("Test:")}   #{cyan(location)}"

        print_source_lines(test_file, lineno) if lineno
      end
    end

    #: (String) -> String?
    def find_test_file(pending_file)
      snapshot_path = Insta.configuration.snapshot_path
      relative = pending_file.sub(%r{\A#{Regexp.escape(snapshot_path)}/}, "")
      test_dir = File.dirname(relative)

      test_file = File.join("test", "#{test_dir}.rb")
      return test_file if File.exist?(test_file)

      nil
    end

    #: (String, String) -> Integer?
    def find_test_line(test_file, method_name)
      lines = File.readlines(test_file)

      lines.each_with_index do |line, i|
        return i + 1 if line.match?(/\bdef\s+#{Regexp.escape(method_name)}\b/)
      end

      description = method_name.sub(/\Atest_\d+_/, "").tr("_", " ")

      lines.each_with_index do |line, i|
        return i + 1 if line.include?("test \"#{description}\"") || line.include?("test '#{description}'")
      end

      nil
    end

    #: (String) -> void
    def display_caller_context(caller_location)
      file, lineno_string = caller_location.split(":", 3).first(2)
      return unless file && lineno_string

      lineno = lineno_string.to_i
      return unless lineno.positive? && File.exist?(file)

      absolute_path = File.expand_path(file)
      puts "  #{dim("Source:")} #{cyan("#{absolute_path}:#{lineno}")}"

      print_source_lines(file, lineno)
    end

    #: (String, String) -> void
    def display_snapshot_paths(original, pending_file)
      puts "  #{dim("Old:")}    #{dim(original)}"
      puts "  #{dim("New:")}    #{dim(pending_file)}"
    end

    #: () -> void
    def print_review_help
      extension = Insta.configuration.snapshot_extension

      puts
      puts "  #{bold(green("a"))}  #{bold(green("accept"))}      " \
           "#{dim("Apply the new snapshot as the current #{extension} file")}"
      puts "  #{bold(red("r"))}  #{bold(red("reject"))}      " \
           "#{dim("Discard the #{extension}.new file and keep the current snapshot")}"
      puts "  #{dim("s")}  #{dim("skip")}        " \
           "#{dim("Skip this snapshot and continue reviewing")}"
      puts "  #{bold(green("A"))}  #{bold(green("accept all"))}  " \
           "#{dim("Accept this and all remaining pending snapshots")}"
      puts "  #{bold(red("R"))}  #{bold(red("reject all"))}  " \
           "#{dim("Reject this and all remaining pending snapshots")}"
      puts "  #{dim("q")}  #{dim("quit")}        " \
           "#{dim("Stop reviewing and exit")}"
      puts
    end

    #: (String, Integer) -> void
    def print_source_lines(file, lineno)
      lines = File.readlines(file)
      start_line = [lineno - 3, 0].max
      end_line = [lineno + 1, lines.length - 1].min

      highlighted = highlight_lines(lines, start_line, end_line)
      puts

      (start_line..end_line).each do |i|
        line_num = i + 1
        prefix = line_num == lineno ? cyan("→ ") : "  "

        puts "  #{prefix}#{dim(format("%4d", line_num))} #{highlighted[i - start_line]}"
      end

      puts
    end

    #: (Array[String], Integer, Integer) -> Array[String]
    def highlight_lines(lines, start_line, end_line)
      snippet = lines[start_line..end_line] || []
      code = snippet.join

      SyntaxHighlight.highlight(code, colorable: color?).lines
    end

    #: (String, String) -> void
    def display_diff(original, pending_file)
      if File.exist?(original)
        old_content = File.read(original)
        new_content = File.read(pending_file)
        extension = File.extname(original).delete_prefix(".")

        puts Diff.diff_with_language(old_content, new_content, file_extension: extension)
      else
        puts "  #{dim("(new snapshot)")}"
        puts File.read(pending_file)
      end
    end

    #: (Symbol, String) -> Symbol
    def process_review_action(action, pending_file)
      case action
      when :accept
        accept_file(pending_file)
        :continue
      when :reject
        reject_file(pending_file)
        :continue
      when :accept_all
        accept_file(pending_file)
        :accept_all
      when :reject_all
        reject_file(pending_file)
        :reject_all
      when :quit
        :quit
      else
        puts "  #{dim("Skipped.")}\n\n"
        :continue
      end
    end

    #: (Array[Inline::pending_store_entry]) -> void
    def review_inline_entries(entries)
      accept_all = false
      reject_all = false

      entries.each do |entry|
        if accept_all
          accept_inline_entry(entry)
          next
        end

        if reject_all
          reject_inline_entry(entry)
          next
        end

        result = review_single_inline_entry(entry)

        case result
        when :accept_all
          accept_all = true
        when :reject_all
          reject_all = true
        when :quit
          puts "Quit."
          break
        end
      end
    end

    #: (Inline::pending_store_entry) -> Symbol
    def review_single_inline_entry(entry)
      file = entry[:file]
      line = entry[:line]

      puts bold("─── inline snapshot ───")
      puts "  #{dim("Source:")} #{cyan("#{File.expand_path(file)}:#{line}")}"

      print_source_lines(file, line) if File.exist?(file)

      old_content = entry[:old_content] || ""
      new_content = entry[:content] || ""

      puts Diff.diff(old_content, new_content)

      action = prompt_review_action
      process_inline_review_action(action, entry)
    end

    #: (Symbol, Inline::pending_store_entry) -> Symbol
    def process_inline_review_action(action, entry)
      case action
      when :accept
        accept_inline_entry(entry)
        :continue
      when :reject
        reject_inline_entry(entry)
        :continue
      when :accept_all
        accept_inline_entry(entry)
        :accept_all
      when :reject_all
        reject_inline_entry(entry)
        :reject_all
      when :quit
        :quit
      else
        puts "  #{dim("Skipped.")}\n\n"
        :continue
      end
    end

    #: (Inline::pending_store_entry) -> void
    def accept_inline_entry(entry)
      file = entry[:file]

      Inline::PendingStore.apply!([entry])
      Inline::PendingStore.remove!([entry])

      @accepted_count = (@accepted_count || 0) + 1

      puts "\n  #{green("✓")} #{File.basename(file)}:#{entry[:line]}"
    end

    #: (Inline::pending_store_entry) -> void
    def reject_inline_entry(entry)
      file = entry[:file]

      Inline::PendingStore.remove!([entry])

      @rejected_count = (@rejected_count || 0) + 1

      puts "\n  #{red("✗")} #{File.basename(file)}:#{entry[:line]}"
    end

    #: () -> void
    def accept
      pending_files = find_pending_files
      inline_entries = Inline::PendingStore.load
      count = pending_files.length + inline_entries.length

      if count.zero?
        puts "#{green("✓")} No pending snapshots to accept."
        return
      end

      pending_files.each { |file| accept_file(file) }

      unless inline_entries.empty?
        Inline::PendingStore.apply!(inline_entries)
        Inline::PendingStore.clean!
      end

      puts "\n#{green("✓")} Accepted #{bold(count.to_s)} #{pluralize(count, "snapshot")}."
    end

    #: () -> void
    def reject
      pending_files = find_pending_files
      inline_entries = Inline::PendingStore.load
      count = pending_files.length + inline_entries.length

      if count.zero?
        puts "#{green("✓")} No pending snapshots to reject."
        return
      end

      pending_files.each { |file| reject_file(file) }
      Inline::PendingStore.clean! unless inline_entries.empty?

      puts "\n#{green("✓")} Rejected #{bold(count.to_s)} #{pluralize(count, "snapshot")}."
    end

    #: () -> void
    def pending_list
      pending_files = find_pending_files
      inline_entries = Inline::PendingStore.load

      if pending_files.empty? && inline_entries.empty?
        puts "#{green("✓")} No pending snapshots."
        return
      end

      total = pending_files.length + inline_entries.length
      puts "#{yellow("●")} Pending snapshots #{dim("(#{total})")}:\n\n"

      print_pending_files(pending_files) unless pending_files.empty?

      return if inline_entries.empty?

      puts unless pending_files.empty?
      print_pending_inline(inline_entries)
    end

    #: (Array[String]) -> void
    def print_pending_files(pending_files)
      locations = PendingLocations.load

      pending_files.each do |pending_file|
        caller_location = locations[pending_file]

        if caller_location
          file, lineno = caller_location.split(":", 3).first(2)
          absolute_path = file ? File.expand_path(file) : nil
          location = absolute_path ? "#{absolute_path}:#{lineno}" : caller_location

          puts "  #{yellow("›")} #{pending_file}"
          puts "    #{dim("at")} #{cyan(location)}"
        else
          puts "  #{yellow("›")} #{pending_file}"
        end
      end
    end

    #: (Array[Inline::pending_store_entry]) -> void
    def print_pending_inline(inline_entries)
      inline_entries.each do |entry|
        file = entry[:file]
        line = entry[:line]
        absolute_path = File.expand_path(file)

        puts "  #{yellow("›")} #{dim("inline")} #{File.basename(file)}:#{line}"
        puts "    #{dim("at")} #{cyan("#{absolute_path}:#{line}")}"
      end
    end

    #: () -> void
    def status
      snapshot_path = Insta.configuration.snapshot_path
      extension = Insta.configuration.snapshot_extension

      puts header
      puts

      all_entries = Dir.exist?(snapshot_path) ? Dir.glob(File.join(snapshot_path, "**", "*")) : [] #: Array[String]
      pending_extension = "#{extension}.new"
      snap_files = all_entries.select { |file|
        File.file?(file) && file.end_with?(extension) && !file.end_with?(pending_extension)
      }
      pending_files = all_entries.select { |file| File.file?(file) && file.end_with?(pending_extension) }
      inline_entries = Inline::PendingStore.load
      directories = all_entries.select { |file| File.directory?(file) }

      print_status_config(snapshot_path, extension)
      print_status_counts(snap_files, pending_files, inline_entries, directories)
      print_status_pending(pending_files, inline_entries)
    end

    #: (String, String) -> void
    def print_status_config(snapshot_path, extension)
      config_entries = [["Snapshot path", snapshot_path], ["Extension", extension]] #: Array[[String, String]]
      print_status_entries(config_entries)
      puts
    end

    #: (Array[String], Array[String], Array[Inline::pending_store_entry], Array[String]) -> void
    def print_status_counts(snap_files, pending_files, inline_entries, directories)
      print_status_entries(
        [
          ["Snapshots", snap_files.length.to_s],
          ["Pending files", pending_files.empty? ? "0" : yellow(pending_files.length.to_s)],
          ["Pending inline", inline_entries.empty? ? "0" : yellow(inline_entries.length.to_s)],
          ["Directories", directories.length.to_s]
        ]
      )
      puts
    end

    #: (Array[String], Array[Inline::pending_store_entry]) -> void
    def print_status_pending(pending_files, inline_entries)
      if pending_files.empty? && inline_entries.empty?
        puts "#{green("✓")} No pending snapshots."
        return
      end

      unless pending_files.empty?
        puts "Pending file snapshots:\n\n"
        pending_files.each { |file| puts "  #{yellow("›")} #{file}" }
        puts
      end

      unless inline_entries.empty?
        puts "Pending inline snapshots:\n\n"
        inline_entries.each { |entry| puts "  #{yellow("›")} #{entry[:file]}:#{entry[:line]}" }
        puts
      end

      puts "  #{cyan("bundle exec insta review")}\n"
    end

    #: (Array[[String, String]]) -> void
    def print_status_entries(entries)
      max_label = entries.map { |label, _| label.length }.max || 0

      entries.each do |label, value|
        dot_count = MIN_GAP + (max_label - label.length)
        dots = dim("·" * dot_count)
        puts "  #{cyan(label)} #{dots} #{value}"
      end
    end

    #: () -> void
    def clean
      snapshot_path = Insta.configuration.snapshot_path

      unless Dir.exist?(snapshot_path)
        puts "#{red("✗")} Snapshot directory does not exist: #{bold(snapshot_path)}"
        return
      end

      all_files = Dir.glob(File.join(snapshot_path, "**", "*"))
      pending_files = all_files.select { |file| file.end_with?(".new") }
      snap_files = all_files - pending_files
      removed = 0

      pending_files.each do |file|
        File.delete(file)
        removed += 1
      end

      inline_entries = Inline::PendingStore.load
      removed += inline_entries.length

      PendingLocations.clean!
      Inline::PendingStore.clean!

      puts "#{green("✓")} Removed #{bold(removed.to_s)} pending #{pluralize(removed, "snapshot")}." if removed.positive?
      puts "  #{dim("#{snap_files.length} snapshot file(s) in #{snapshot_path}")}"
    end

    #: () -> void
    def help
      puts header
      puts
      puts dim("Description:")
      puts "  Snapshot tests assert values against a reference value. Think of it as"
      puts "  a supercharged version of #{cyan("assert_equal")} where the reference value is"
      puts "  managed by #{bold("insta")} for you."
      puts

      print_usage
      print_section("Commands:", help_commands)
      print_section("Options:", help_options)
      print_section("Environment:", help_environment)
    end

    #: () -> void
    def print_usage
      puts dim("Usage:")
      puts "  insta #{dim("<command>")} #{dim("[options]")}"
      puts
    end

    #: (String, Array[[String, String]]) -> void
    def print_section(title, entries)
      puts dim(title)

      max_label = entries.map { |label, _| label.length }.max || 0

      entries.each do |label, description|
        dot_count = MIN_GAP + (max_label - label.length)
        dots = dim("·" * dot_count)

        puts "  #{cyan(label)} #{dots} #{description}"
      end

      puts
    end

    #: () -> String
    def header
      "#{bold("insta")} v#{Insta::VERSION} #{dim("📸 Snapshot Testing for Ruby")}"
    end

    #: () -> void
    def version
      puts header
    end

    #: () -> Array[[String, String]]
    def help_commands
      [
        ["review", "Interactive review of pending snapshots"],
        ["accept", "Accept all pending snapshots"],
        ["reject", "Reject all pending snapshots"],
        ["pending", "List pending snapshots"],
        ["status", "Show snapshot overview and pending files"],
        ["clean", "Remove pending snapshot files"],
        ["help", "Display usage information"]
      ]
    end

    #: () -> Array[[String, String]]
    def help_options
      [
        ["-h, --help", "Display usage information"],
        ["-v, --version", "Display version information"]
      ]
    end

    #: () -> Array[[String, String]]
    def help_environment
      [
        ["INSTA_UPDATE=<mode>", "Set update mode #{dim("[auto|always|new|no]")}"],
        ["INSTA_FORCE_PASS=1", "Create .snap.new without failing tests"]
      ]
    end

    #: () -> Array[String]
    def find_pending_files
      snapshot_path = Insta.configuration.snapshot_path

      Dir.glob(File.join(snapshot_path, "**", "*.new"))
    end

    #: (String) -> void
    def accept_file(pending_file)
      original = pending_file.sub(/\.new\z/, "")
      File.rename(pending_file, original)

      @accepted_count = (@accepted_count || 0) + 1

      puts "\n  #{green("✓")} #{File.basename(original)}"
    end

    #: (String) -> void
    def reject_file(pending_file)
      File.delete(pending_file)

      @rejected_count = (@rejected_count || 0) + 1

      puts "\n  #{red("✗")} #{File.basename(pending_file)}"
    end

    #: () -> void
    def print_review_summary
      parts = [] #: Array[String]
      parts << green("#{@accepted_count} accepted") if @accepted_count.positive?
      parts << red("#{@rejected_count} rejected") if @rejected_count.positive?

      remaining_files = find_pending_files
      remaining_inline = Inline::PendingStore.load
      remaining_count = remaining_files.length + remaining_inline.length
      parts << yellow("#{remaining_count} skipped") if remaining_count.positive?

      summary = parts.any? ? " #{dim("(")}#{parts.join(dim(", "))}#{dim(")")}" : ""
      puts

      if remaining_count.zero?
        puts "#{green("✓")} Review complete.#{summary}"
      else
        puts "#{green("✓")} Review complete.#{summary}"
        puts "\n  #{cyan("bundle exec insta review")}\n\n"
      end
    end
  end
end
