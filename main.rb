#!/usr/bin/env ruby

require "mumble-ruby"
require "ipaddress"

SERVER = "ape3000.com"
NAME = "Botti"
CHANNEL = "Ape"
BITRATE = 72000
SAMPLE_RATE = 48000
ADMINS = ["Ape"]

class Botti
	class AlreadyRunning < StandardError; end

	LastSeenRecord = Struct.new(:name, :time)

	def initialize
		@running = false

		@cli = Mumble::Client.new(SERVER) do |conf|
			conf.username = NAME
			conf.bitrate = BITRATE
			conf.sample_rate = SAMPLE_RATE
			conf.ssl_cert_opts[:cert_dir] = File.expand_path("./")
		end

		@lastseen = []

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
		@cli.on_text_message do |msg|
			handle_message(msg)
		end

		@cli.on_user_state do |state|
			handle_user_state(state)
		end

		@cli.on_user_remove do |info|
			handle_user_remove(info.session)
		end

		@cli.on_connected do
			@cli.me.deafen
			@cli.join_channel(CHANNEL)
		end

		@stats_callback = nil

		@cli.on_user_stats do |stats|
			if !@stats_callback.nil?
				@stats_callback.call(stats)
				@stats_callback = nil
			end
		end
	end

	def read_input
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
			handle_command(nil, input.chomp)
		end
	end

	def send_message(message)
		@cli.me.current_channel.send_text(message)
	end

	def log(message)
		puts
		puts message
		print ">> "
		$stdout.flush
	end

	def output(user, message)
		if user.nil?
			log(message)
		else
			send_message(message)
		end
	end

	def output_bold(user, message)
		output(user, "<b>#{message}</b>")
	end

	def output_error(user, message)
		output_bold(user, "<span style='color:#ff0000'>#{message}</span>")
	end

	def handle_command(user, command)
		cmd, arg = command.split(" ", 2)

		if cmd == "exit" && isadmin(user)
			cmd_exit(user, arg)
		elsif cmd == "text" && isadmin(user)
			cmd_text(user, arg)
		elsif cmd == "channel" && isadmin(user)
			cmd_channel(user, arg)
		elsif cmd == "ip"
			cmd_ip(user, arg)
		elsif cmd == "ping"
			cmd_ping(user, arg)
		elsif cmd == "idle"
			cmd_idle(user, arg)
		elsif cmd == "lastseen"
			cmd_lastseen(user, arg)
		elsif cmd == "stream"
			output_bold(user, "rtmp://ape3000.com/live/asd")
		else
			output_error(user, "Unknown command: #{cmd}")
		end
	end

	def cmd_exit(user, arg)
		puts "Exiting..."
		$stdin.close
		@running = false
	end

	def cmd_text(user, arg)
		if arg.nil?
			output_bold(user, "Usage: text &lt;message&gt;")
			return
		end

		send_message(arg)
	end

	def cmd_channel(user, arg)
		if arg.nil?
			output_bold(user, "Usage: channel &lt;channel&gt;")
			return
		end

		channel = @cli.find_channel(arg)
		if channel.nil?
			output_error(user, "Error: Cannot find channel '#{arg}'.")
		else
			@cli.join_channel(channel)
		end
	end

	def cmd_ip(user, arg)
		if arg.nil?
			output_bold(user, "Usage: ip &lt;user&gt;")
			return
		end

		target = find_channel_user(arg)
		if target.nil?
			output_error(user, "Error: Cannot find user '#{arg}'.")
		else
			request_stats(target) do |stats|
				address = IPAddress::IPv6.parse_data(stats.address).compressed

				if address[0..6] == "::ffff:"
					address = IPAddress::IPv6::Mapped.parse_data(stats.address).ipv4.address
				end

				output(user, "<br />\n"\
				             "<h1>#{address}</h1><br />\n")
			end
		end
	end

	def cmd_ping(user, arg)
		if arg.nil?
			output_bold(user, "Usage: ping &lt;user&gt;")
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
			output_bold(user, "Usage: idle &lt;user&gt;")
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
		if @lastseen.length > 0
			result = ([""] + @lastseen.map { |x| "#{x.name}: #{x.time.strftime("%H:%M")}" }).join("<br />\n")
			output_bold(user, result)
		else
			output_bold(user, "No users.")
		end
	end

	def interval_format(seconds)
		if seconds < 60*60
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
		return if @cli.me.nil? # Not fully connected yet

		user = @cli.users[state.actor]

		if state.has_key? "channel_id"
			if state["channel_id"] == @cli.me.current_channel.channel_id
				if state.has_key?("name")
					handle_join(state.name)
				else
					handle_join(user.name)
				end
			else
				handle_leave(user.name)
			end
		else
			log("Unknown state change: #{state}")
		end
	end

	def handle_user_remove(session)
		return if @cli.me.nil? # Not fully connected yet

		user = @cli.users[session]

		if user.channel_id == @cli.me.current_channel.channel_id
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
end

bot = Botti.new
bot.run
