#!/usr/bin/env ruby

require "mumble-ruby"
require "ipaddress"
require "open3"
require "cgi"
require "fileutils"

SERVER = "ape3000.com"
NAME = "Botti"
CHANNEL = "Ape"
BITRATE = 72000
SAMPLE_RATE = 48000
ADMINS = ["Ape"]
MEMO_DIRECTORY = "memo"
CERT_OPTIONS = {
  :cert_dir => "certificates",
  :country_code => "FI",
  :organization => "Ape3000.com",
  :organization_unit => "Bot",
}

class Botti
  class AlreadyRunning < StandardError; end

  LastSeenRecord = Struct.new(:name, :time)

  def initialize
    @running = false
    @lastseen = []
    @lognewline = false

    FileUtils.mkdir_p(CERT_OPTIONS[:cert_dir])

    @cli = Mumble::Client.new(SERVER) do |conf|
      conf.username = NAME
      conf.bitrate = BITRATE
      conf.sample_rate = SAMPLE_RATE
      conf.ssl_cert_opts = CERT_OPTIONS
    end

    setup_callbacks
  end

  def run
    raise AlreadyRunning if @running

    @running = true
    @cli.connect

    while @running do
      read_input
    end

    @cli.disconnect
    @running = false
  end

  private

  def setup_callbacks
    @cli.on_connected do
      @cli.me.deafen
      @cli.join_channel(CHANNEL)
    end

    @cli.on_user_state do |state|
      handle_user_state(state)
    end

    @cli.on_user_remove do |info|
      handle_user_remove(info.session)
    end

    @cli.on_text_message do |msg|
      handle_message(msg)
    end

    @stats_callback = nil

    @cli.on_user_stats do |stats|
      unless @stats_callback.nil?
        @stats_callback.call(stats)
        @stats_callback = nil
      end
    end
  end

  def read_input
    @lognewline = true
    print "> "
    $stdout.flush

    begin
      input = gets || "exit"
    rescue IOError
      @running = false
    else
      @lognewline = false
      handle_command(nil, input.chomp)
    end
  end

  def send_message(message)
    @cli.me.current_channel.send_text(message)
  end

  def send_image(path)
    @cli.me.current_channel.send_image(path)
  end

  def log(message)
    if @lognewline
      @lognewline = false
      puts
    end

    puts "[#{Time.now.strftime("%H:%M")}] #{message}"
  end

  def output(user, message)
    unless message.empty?
      if user.nil?
        log(message)
      else
        send_message(message)
      end
    end
  end

  def output_bold(user, message)
    output(user, "<b>#{message}</b>") unless message.empty?
  end

  def output_error(user, message)
    unless message.empty?
      output_bold(user, "<span style='color:#ff0000'>#{message}</span>")
    end
  end

  def handle_command(user, command)
    cmd, arg = split_command(command)

    if cmd == "help"
      cmd_help(user, arg)
    elsif cmd == "exit" && isadmin?(user)
      cmd_exit(user, arg)
    elsif cmd == "text" && isadmin?(user)
      cmd_text(user, arg)
    elsif cmd == "channel" && isadmin?(user)
      cmd_channel(user, arg)
    elsif cmd == "python" && isadmin?(user)
      cmd_python(user, arg)
    elsif cmd == "ip"
      cmd_ip(user, arg)
    elsif cmd == "ping"
      cmd_ping(user, arg)
    elsif cmd == "idle"
      cmd_idle(user, arg)
    elsif cmd == "lastseen"
      cmd_lastseen(user, arg)
    elsif cmd == "math"
      cmd_math(user, arg)
    elsif cmd == "memo"
      cmd_memo(user, arg)
    elsif cmd == "addmemo"
      cmd_addmemo(user, arg)
    elsif cmd == "delmemo"
      cmd_delmemo(user, arg)
    else
      output_error(user, "Unknown command: #{cmd}")
    end
  end

  def split_command(command)
    [" ", "<br />"].map { |x| command.split(x, 2) }
                   .min_by { |x| x[0].length unless x[0].nil? }
  end

  def cmd_help(user, arg)
    output_bold(user, format_lines([
      "!ip <user>",
      "!ping <user>",
      "!idle <user>",
      "!lastseen",
      "!math <formula>",
      "!memo <name>",
      "!addmemo <name> <text>",
      "!delmemo <name>",
    ]))
  end

  def cmd_exit(user, arg)
    puts "Exiting..."
    $stdin.close
    @running = false
  end

  def cmd_text(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: text <message>"))
      return
    end

    send_message(to_html(arg))
  end

  def cmd_channel(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: channel <channel>"))
      return
    end

    channel = @cli.find_channel(arg)
    if channel.nil?
      output_error(user, "Error: Cannot find channel '#{arg}'.")
    else
      @cli.join_channel(channel)
    end
  end

  def cmd_python(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: python <code>"))
      return
    end

    # Echo the code back with fixed white-space if needed
    lines = from_html(arg).split("\n")
    if lines.any? { |x| x.start_with? " " }
      output(user, format_lines(lines))
    end

    # Add print to one-liners
    if lines.length == 1 && !lines[0].start_with?("print")
      lines[0] = "print(#{lines[0]})"
    end

    # Execute
    stdin, stdout, stderr = Open3.popen3('python')
    stdin.puts(lines.join("\n"))
    stdin.close

    output_bold(user, format_lines(stdout.readlines))
    output_error(user, format_lines(stderr.readlines))
  end

  def cmd_ip(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: ip <user>"))
      return
    end

    target = find_channel_user(arg)
    if target.nil?
      output_error(user, "Error: Cannot find user '#{arg}'.")
    else
      request_stats(target) do |stats|
        address = IPAddress::IPv6.parse_data(stats.address).compressed

        if address.start_with? "::ffff:"
          address = IPAddress::IPv6::Mapped.parse_data(stats.address).ipv4.address
        end

        output(user, "<br />\n"\
                     "<h1>#{address}</h1><br />\n")
      end
    end
  end

  def cmd_ping(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: ping <user>"))
      return
    end

    target = find_channel_user(arg)
    if target.nil?
      output_error(user, "Error: Cannot find user '#{arg}'.")
    else
      request_stats(target) do |stats|
        output(user, format_stats(stats))
      end
    end
  end

  def format_stats(stats)
    total_to = total_packets(stats.from_server)
    total_from = total_packets(stats.from_client)

    "<br />\n"\
    "<b>TCP:</b> #{ping_stats(stats.tcp_ping_avg, stats.tcp_ping_var)}<br />\n"\
    "<b>UDP:</b> #{ping_stats(stats.udp_ping_avg, stats.udp_ping_var)}<br />\n"\
    "<b>Loss-&gt;:</b> #{loss_percentage(stats.from_server.lost, total_to)} / "\
    "#{loss_percentage(stats.from_server.late, total_to)}<br />\n"\
    "<b>Loss&lt;-:</b> #{loss_percentage(stats.from_client.lost, total_from)} / "\
    "#{loss_percentage(stats.from_client.late, total_from)}"
  end

  def total_packets(info)
    [info.lost, info.late, info.good].reduce(:+)
  end

  def ping_stats(average, variance)
    "#{format("%.1f", average)} ± #{format("%.1f", Math.sqrt(variance))} ms"
  end

  def loss_percentage(packets, total)
    percentage = (0 if total.zero?) || 100.0 * packets / total
    "#{format("%.2f", percentage)} %"
  end

  def cmd_idle(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: idle <user>"))
      return
    end

    target = find_channel_user(arg)
    if target.nil?
      output_error(user, "Error: Cannot find user '#{arg}'.")
    else
      request_stats(target) do |stats|
        output_bold(user, "#{interval_format(stats.idlesecs)}")
      end
    end
  end

  def cmd_lastseen(user, arg)
    @lastseen.delete_if { |x| (Time.new - x.time) > 60*60*22 }

    if @lastseen.length > 0
      lines = @lastseen.map { |x| "#{x.name}: #{x.time.strftime("%H:%M")}" }
      output_bold(user, format_lines(lines))
    else
      output_bold(user, "No users.")
    end
  end

  def cmd_math(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: math <formula>"))
      return
    end

    File.write("math.tex", from_html(arg))
    %x(tex2im math.tex) # Writes math.png

    # Only show non-empty output images to prevent some problematic behavior
    if %x(identify -format %[standard-deviation] math.png) == "-nan"
      output_bold(user, "No output.")
    else
      send_image("math.png")
    end
  end

  def cmd_memo(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: memo <name>"))
      return
    end

    unless arg.match(/^[[:alnum:]]+$/)
      output_error(user, "Error: Only alphanumeric names are allowed.")
      return
    end

    begin
      text = File.read("#{MEMO_DIRECTORY}/#{arg}")
    rescue SystemCallError
      output_error(user, "Memo '#{arg}' not found.")
    else
      output_bold(user, text)
    end
  end

  def cmd_addmemo(user, arg)
    if arg.nil? || arg.split(" ", 2).length < 2
      output_bold(user, to_html("Usage: addmemo <name> <text>"))
      return
    end

    name, text = arg.split(" ", 2)

    if name.length > 20
      output_error(user, "Error: Maximum name length is 20 characters.")
      return
    end

    unless name.match(/^[[:alnum:]]+$/)
      output_error(user, "Error: Only alphanumeric names are allowed.")
      return
    end

    FileUtils.mkdir_p(MEMO_DIRECTORY)
    File.write("#{MEMO_DIRECTORY}/#{name}", text)

    output_bold(user, "Memo '#{name}' saved.")
  end

  def cmd_delmemo(user, arg)
    if arg.nil?
      output_bold(user, to_html("Usage: delmemo <name>"))
      return
    end

    unless arg.match(/^[[:alnum:]]+$/)
      output_error(user, "Error: Only alphanumeric names are allowed.")
      return
    end

    begin
      File.delete("#{MEMO_DIRECTORY}/#{arg}")
    rescue SystemCallError
      output_error(user, "Memo '#{arg}' not found.")
    else
      output_bold(user, "Memo '#{arg}' deleted.")
    end
  end

  def interval_format(seconds)
    if seconds < 60*60*24
      Time.at(seconds).utc.strftime("%H:%M:%S")
    else
      "More than a day"
    end
  end

  def find_channel_user(name)
    @cli.me.current_channel.users.find { |u| u.name == name}
  end

  def request_stats(user, &block)
    @stats_callback = block
    user.stats
  end

  def isadmin?(user)
    user.nil? || (ADMINS.include? user.name)
  end

  def on_same_channel?(user)
    !@cli.me.nil? && !user.nil? && user.channel_id == @cli.me.channel_id
  end

  def handle_message(msg)
    if msg.actor.nil?
      log("$ #{msg.message}")
    else
      sender = @cli.users[msg.actor]
      log("#{sender.name}: #{msg.message}")

      if msg.message[0] == "!"
        handle_command(sender, msg.message[1..-1])
      end
    end
  end

  def handle_user_state(state)
    user = @cli.users[state.session]

    if state.has_key? "channel_id"
      if !@cli.me.nil? && state["channel_id"] == @cli.me.channel_id
        if state.has_key? "name"
          handle_join(state.name)
        elsif !user.nil?
          handle_join(user.name)
        end
      elsif on_same_channel?(user)
        handle_leave(user.name)
      end
    end
  end

  def handle_user_remove(session)
    user = @cli.users[session]

    if on_same_channel?(user)
      handle_leave(user.name)
    end
  end

  def handle_join(name)
    log("#{name} joined.")

    @lastseen.delete_if { |x| x.name == name }
  end

  def handle_leave(name)
    log("#{name} left.")

    @lastseen.delete_if { |x| x.name == name }
    @lastseen.unshift LastSeenRecord.new(name, Time.new)
    @lastseen = @lastseen.take(5)
  end

  def format_lines(lines)
    if lines.length >= 2
      lines.unshift ""
    end

    to_html(lines.map { |x| x.chomp }
                 .join("\n"))
  end

  def to_html(string)
    CGI.escapeHTML(string).chomp.gsub(/ /, "&nbsp;").gsub(/\n/, "<br />")
  end

  def from_html(string)
    CGI.unescapeHTML(string.gsub(/<br \/>/, "\n").gsub(/&nbsp;/, " "))
  end
end

bot = Botti.new
bot.run
