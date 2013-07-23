require 'open3'
require 'rubygems'
require 'nokogiri'

module Maven
  def self.pom_dir(path)
    if path == '/'
      nil
    elsif File.exists?(path + '/pom.xml')
      path
    else
      pom_dir(File.dirname(path))
    end
  end

  def self.bb_goto_pom_dir!
    doc_path = ENV['BB_DOC_PATH']
    STDERR.puts('no document open') and exit 1 if doc_path.nil?
    pd = pom_dir(doc_path)
    STDERR.puts('no pom found') and exit 1 if pd.nil?
    Dir.chdir(pd)
  end

  def self.compilation_error(line, mvn_out, log)
    error = nil
    if line =~ /^\[ERROR\] (\/.+):(\d+): error: (.*)/
      error = { :file => $1.dup, :line => $2.dup, :error => $3.dup }

      if $3 == 'type mismatch;'
        line = mvn_out.gets.chomp
        log.puts(line)
        line =~ /^\[ERROR\].*?: (.*)/
        found = $1.dup

        line = mvn_out.gets.chomp
        log.puts(line)
        line =~ /^\[ERROR\].*?: (.*)/
        required = $1.dup

        error[:error] << " found #{found}, required #{required}"
      end
    end
    error
  end

  def self.surefire_errors
    errors = []
    Dir.foreach('target/surefire-reports') do |entry|
      next unless entry =~ /^TEST-.+\.xml$/
      doc = Nokogiri::XML::Document.parse(File.read('target/surefire-reports/' + entry))
      doc.search('error').each do |error|
        stack_trace = error.child.text.split(/\n\s*/)
        stack_trace.shift
        stack_trace = stack_trace.drop_while do |line|
          if line =~ /\((.+(Specs?|Tests?)\.[^\.]+):\d+\)/
            path = Dir.glob('**/' + $1)
            path.nil? || path.empty?
          else
            true
          end
        end

        if !stack_trace.first.nil?
          stack_trace.first =~ /\((.+):(\d+)\)/
          errors << { :file => Dir.pwd + '/' + Dir.glob('**/' + $1).first, :line => $2.dup, :error => error['message'].dup }
        end
      end
    end
    errors
  end

  def self.bb_results(errors)
    unless errors.empty?
      error_list = errors.map do |error|
        '{result_kind:error_kind, result_file:' + error[:file].inspect +
          ', result_line:' + error[:line] +
          ', message:' + error[:error].inspect + '}'
      end

      Open3.popen3('osascript') do |osa_in, osa_out, osa_err|
        osa_in.write('tell application "BBEdit" to make new results browser with data {' +
          error_list.join(',') + '} with properties {name:"Test Results"}')
      end
    end
  end

  def self.mvn(command)
    errors = []
    tests_failed = false

    File.open('mvn.out', 'w') do |log|
      Open3.popen3('mvn ' + command) do |mvn_in, mvn_out, mvn_err|
        until mvn_out.eof? do
          line = mvn_out.gets.chomp.strip
          log.puts(line)
          tests_failed = true if line == 'Tests in error:'

          error = compilation_error(line, mvn_out, log)
          errors << error if error
        end
        log.write(mvn_err.read)
      end
    end

    errors += surefire_errors if tests_failed

    bb_results(errors)
  end
end
