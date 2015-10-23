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
CERT_DIRECTORY = "certificates"
CERT_COUNTRY = "FI"
CERT_ORGANIZATION = "Ape3000.com"
CERT_UNIT = "Bot"

class Botti
	class AlreadyRunning < StandardError; end

	LastSeenRecord = Struct.new(:name, :time)

	def initialize
		@running = false
		@lastseen = []
		@lognewline = false

		FileUtils.mkdir_p(CERT_DIRECTORY)

		@cli = Mumble::Client.new(SERVER) do |conf|
			conf.username = NAME
			conf.bitrate = BITRATE
			conf.sample_rate = SAMPLE_RATE
			conf.ssl_cert_opts = {
				cert_dir: CERT_DIRECTORY,
				country_code: CERT_COUNTRY,
				organization: CERT_ORGANIZATION,
				organization_unit: CERT_UNIT,
			}
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
			input = gets

			if input.nil?
				input = "exit"
			end
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
		output_bold(user, "<span style='color:#ff0000'>#{message}</span>") unless message.empty?
	end

	def handle_command(user, command)
		cmd, arg = split_command(command)

		if cmd == "help"
			cmd_help(user, arg)
		elsif cmd == "exit" && isadmin(user)
			cmd_exit(user, arg)
		elsif cmd == "text" && isadmin(user)
			cmd_text(user, arg)
		elsif cmd == "channel" && isadmin(user)
			cmd_channel(user, arg)
		elsif cmd == "python" && isadmin(user)
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
		elsif cmd == "stream"
			output_bold(user, "rtmp://ape3000.com/live/asd")
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
			"!stream",
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
				total_to = stats.from_server.lost + stats.from_server.late + stats.from_server.good + 0.00001
				total_from = stats.from_client.lost + stats.from_client.late + stats.from_client.good + 0.00001

				output(user, "<br />\n"\
				             "<b>TCP:</b> #{format("%.1f", stats.tcp_ping_avg)} ± #{format("%.1f", Math.sqrt(stats.tcp_ping_var))} ms<br />\n"\
				             "<b>UDP:</b> #{format("%.1f", stats.udp_ping_avg)} ± #{format("%.1f", Math.sqrt(stats.udp_ping_var))} ms<br />\n"\
				             "<b>Loss-&gt;:</b> #{format("%.2f", 100 * stats.from_server.lost / total_to)} % / #{format("%.2f", 100 * stats.from_server.late / total_to)} %<br />\n"\
				             "<b>Loss&lt;-:</b> #{format("%.2f", 100 * stats.from_client.lost / total_from)} % / #{format("%.2f", 100 * stats.from_client.late / total_from)} %")
			end
		end
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
			output_bold(user, format_lines(@lastseen.map { |x| "#{x.name}: #{x.time.strftime("%H:%M")}" }))
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

	def interval_format(seconds)
		if seconds < 60*60*24
			return Time.at(seconds).utc.strftime("%H:%M:%S")
		else
			return "More than a day"
		end
	end

	def find_channel_user(name)
		@cli.me.current_channel.users.find { |u| u.name == name}
	end

	def request_stats(user, &block)
		@stats_callback = block
		user.stats
	end

	def isadmin(user)
		user.nil? || (ADMINS.include? user.name)
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
		return if @cli.me.nil? || @cli.me.current_channel.nil? # Not fully connected yet

		user = @cli.users[state.session]

		if state.has_key? "channel_id"
			if state["channel_id"] == @cli.me.current_channel.channel_id
				if state.has_key? "name"
					handle_join(state.name)
				elsif !user.nil?
					handle_join(user.name)
				end
			elsif !user.nil? && !user.current_channel.nil? && user.current_channel.channel_id == @cli.me.current_channel.channel_id
				handle_leave(user.name)
			end
		end
	end

	def handle_user_remove(session)
		return if @cli.me.nil? || @cli.me.current_channel.nil? # Not fully connected yet

		user = @cli.users[session]

		if !user.nil? && user.channel_id == @cli.me.current_channel.channel_id
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
