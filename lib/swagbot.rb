#!/usr/bin/env ruby

# SWAGBOT
#
# Maintained by Timothy Williams <tiwillia@redhat.com>

class Swagbot

require 'socket'
require 'open-uri'
require 'json/ext'
require 'rubygems'
require 'active_record'
require 'yaml'
require 'pg'
require 'nokogiri'

# Initialize variables
def initialize(params)
	@timers = Hash.new
  @userposting = "nil"
  @host = params[:server]
	@port = params[:port]
	@nick = params[:nick]
	@chan = params[:channel]
  @server_password = params[:server_password]
  @nickserv_password = params[:nickserv_password]
  @bot = params[:bot]
end

# Small function to easily send commands
def send(msg)
	@socket.send "#{msg}\n", 0
end

# Small function to easily send messages to @chan
def sendchn(msg)
	@socket.send ":source PRIVMSG #{@chan} :#{msg}\n" , 0
end

def join_chan(chan)
	send ":source JOIN #{chan}"
end

def leave_chan(chan)
	send ":source PART #{chan}"
end

# This must be run fist
# It opens up the socket connection
# Logs in with the specified @nick
# And joins the @chan
def connect()
	@socket = TCPSocket.open(@host, @port)
  if not @server_password == ""
    send "PASS #{@server_password}"
  end
	send "USER #{@nick} 0 * #{@nick}"
	send "NICK #{@nick}"
  if not @nickserv_password == ""
    send ":source PRIVMSG userserv :login #{@nick} #{@nickserv_password}"
  end
	send "JOIN #{@chan}"
end

# Closes the socket connection
def kill()
	@socket.send(":source QUIT :SWAG\n", 0)
	@socket.close
end

# Create a user and id if it doesn't exist
# Return the corresponding User ActiveRecord::Relation object
def getuser(user)
  if Users.where(:user => user).present?
    Users.find_by_user(user)
  else
    new_user = Users.new(user: user)
    new_user.save
    new_user
  end
end

def getuser_by_id(id)
  if Users.where(:id => id).present?
    Users.find(id)
  else
    nil 
  end
end

# Random number generator, excludes 0
def rdnum(seq)
  today = DateTime.now
  seed = today.strftime(format='%3N').to_i
  prng = Random.new(seed)
  prng.rand(1..seq)
end

# Add or subtract Karma
def editkarma(giver, receiver, type)
	#Here we need to parse the db for name, get the number, add one to the number
	#Syntax of the db will be user:number\n
  recipient = getuser(receiver)
  grantor = Users.find_by_user(giver)

  # Add timer
  # check for the timer before we set the timer, obviously.
  time = @timers.fetch(receiver, nil)
  if time.to_i != 0
    if time.to_i > (Time.now.to_i - CONFIG[:karma_timeout])
      send(":source PRIVMSG #{@userposting} :You must wait #{time.to_i - (Time.new.to_i - CONFIG[:karma_timeout])} more seconds before changing #{receiver}'s karma.\n")
      return
    elsif time.to_i < (Time.now.to_i - CONFIG[:karma_timeout])
      @timers = { receiver => Time.new.to_i }
    end
  else
    @timers = { receiver => Time.new.to_i }
  end

  # Set the Karma Amount
  case
	when type.eql?("add")
		karma_amount = 1 
	when type.eql?("subtract")
		karma_amount = -1
	else
		karma_amount = 0
	end
  
  
  # Create the new karma row
  karma_entry = Karma.create(grantor_id: grantor.id, recipient_id: recipient.id, amount: karma_amount)  
  karma_entry.save

  # Update the user's karma running total in karmastats
  if Karmastats.where(user_id: recipient.id).present?
    stat = Karmastats.find_by_user_id(recipient.id)
    stat.total = stat.total + karma_amount
    stat.save
  else
    stat = Karmastats.new(user_id: recipient.id, total: karma_amount)
    stat.save
  end  

	sendchn("#{receiver} now has #{stat.total} karma.")
end

def rank(who)
	#Here we are going to create a rank command
	#If no who is specified, list the top 5
	#if a who is specified, display their rank.
	#Might also use this as a way to add on the to editkarma command
  counter = 1
  Karmastats.where(:total != 0).order('total DESC').each do |x|
    x.rank = counter
    x.save
    counter += 1
  end

  if who == "all"
		Karmastats.where(:total != 0).order('rank ASC').limit(5).each do |x|
      user_obj = Users.find(x.user_id)
			sendchn("#{x.rank}: #{user_obj.user} with #{x.total} points of karma")
		end
	else
		user = getuser(who)

    if Karmastats.where(user_id: user.id).present?
      stat = Karmastats.find_by_user_id(user.id)
      rank = stat.rank
      case
      when rank.to_s.match(/^1.$/)
        suffix = "th"
      when rank.to_s.match(/.*[4-9,0]$/)
        suffix = "th"
      when rank.to_s.match(/.*3$/)
        suffix = "rd"
      when rank.to_s.match(/.*2$/)
        suffix = "nd"
      when rank.to_s.match(/.*1$/)
        suffix = "st"
      end
      sendchn("#{user.user} is #{rank}#{suffix} with #{stat.total} points of karma")
    else
      sendchn("#{user.user} has never had karma added or subtracted.")
    end
	end
end

# Adds a quote
def addquote(recorder, quotee, quote)
  recorder = getuser(recorder)
  quotee = getuser(quotee)
  quote_obj = Quotes.new(recorder_id: recorder.id, quotee_id: quotee.id, quote: quote)
	quote_obj.save
  sendchn("Quote for #{quotee.user} added with id: #{quote_obj.id}")
end

# Reads a quote
def echo_quote_by_user(who)
  if Quotes.count.zero?
    sendchn("No quotes have ever been added, use \"#{@nick}, addquote user quote\" to add one.") 
    return
  end
  quotee = getuser(who)
  if Quotes.where(quotee_id: quotee.id).present?
    quote = Quotes.where(quotee_id: quotee.id).first(:offset => rand(Quotes.where(quotee_id: quotee.id).count))
    sendchn("\"#{quote.quote}\" - #{quotee.user} \| id:#{quote.id}")
  else
    sendchn("#{quotee.user} has never been quoted")
  end
end

def echo_random_quote(chan)
  sendchn("No quotes have ever been added, use \"#{@nick}, addquote user quote\" to add one.") and return if Quotes.all.empty?
  quote_ar = Array.new
  Quotes.all.each { |q| quote_ar << q.id }
  id = quote_ar[rdnum(Quotes.count) - 1]
  quote = Quotes.find(id.to_i)
  quotee = Users.find(quote.quotee_id)
  sendchn("\"#{quote.quote}\" - #{quotee.user} \| id:#{quote.id}")
end

def echo_quote_by_id(id)
  sendchn("No quotes have ever been added, use \"#{@nick}, addquote user quote\" to add one.") and return if Quotes.all.empty?
  if Quotes.where(id: id).present?
    quote = Quotes.find(id)
    quotee = getuser_by_id(quote.quotee_id)
    sendchn("\"#{quote.quote}\" - #{quotee.user} \| id:#{quote.id}")
  else
     sendchn("No quote with id: #{id} exists.")
  end
end

# This will grab the title and possibly description of a bugzilla link and display it
def bugzilla(url)
  doc = Nokogiri::HTML(open(url))
  number = url.split("=").last
  title = doc.xpath('//span[@id="short_desc_nonedit_display"]/text()')
  status = doc.xpath('//span[@id="static_bug_status"]/text()')
  sendchn("Bugzilla: ##{number} \"#{title}\" : #{status}")
end

# This will grab the title of a youtube link and display it
def youtube(url)
  doc = Nokogiri::HTML(open(url))
  title = doc.xpath('//span[@id="eow-title"]/@title')
  views = doc.css('span.watch-view-count').first.content.strip
  sendchn("Youtube: \"#{title}\" : #{views} views")
end

# This will grab the title of an imgur link and display it
def imgur(url)
  doc = Nokogiri::HTML(open(url)) rescue nil
  img_id = url.split("/").last
  title = doc.xpath('//h2[@id="image-title"]/text()')
  time = doc.xpath('//span[@id="nicetime"]/text()')
  if time.empty?
    time = doc.xpath('//div[@id="stats-submit-date"]/text()')
    time = time.text.strip.gsub(/\ (\ +)/,"").gsub("\n", " ")
  else
    time = "Submitted #{time}"
  end
  sendchn("Imgur: \"#{title}\" #{time}")
end

# Definitions can be accessed with the echo_definition method
def add_definition(word, definition, recorder)
	recorder = getuser(recorder)
  word = word.downcase
  definition = Definitions.create(recorder_id: recorder.id, word: word, definition: definition)
  definition.save
  sendchn("Ok, I'll remember #{word}")
end

def forget_definition(word)
  word = word.downcase
	definition = Definitions.where(word: word).order('id ASC')
  if definition.present?
    definition.last.destroy
    sendchn("Deleted #{word}'s latest definition.")
	else
		sendchn("How can I forget what I do not know?")
	end
end

# Sends the definition added with add_definition
def echo_definition_by_word(word)
  word = word.downcase
  if !Definitions.where(word: word).blank?
	  Definitions.where(word: word).each do |d|
      sendchn("#{d.word} is #{d.definition}")
    end
  end
end

def echo_definition_by_id(id)
  Definitions.where(id: id).each do |d|
      sendchn("#{d.word} is #{d.definition}")
  end 
end

def echo_definition_by_user(who)
  Definitions.where(recorder: who).each do |d|
      sendchn("#{d.word} is #{d.definition}")
  end
end
# This is also where we evaluate what is said in the channel
# If you would like to add a commad (swagbot: command) do it in the first case statement
# Otherwise, use the second one.
def loop()
	line = @socket.gets
  line = line.strip
		  
  # Grab the nick of the @userposting
  @userposting = line[/^:([\|\.\-0-9a-zA-Z]*)!/, 1]
	if line.match(/^:.*\ PRIVMSG\ #{@nick}\ \:.*/)
    @chan = @userposting
	else
		@chan = line[/\ (#[\|\.\-0-9a-zA-Z]*)\ :/, 1]
	end
	
  # Ignore unifiedbot
  if @userposting.eql?("unifiedbot")
    return
	end

  # Add the user to the users table if they do not exist
  if !@userposting.blank?
    if Users.where(user: @userposting).blank?
      new_user = Users.create(user: @userposting)
      new_user.save
    end	
  end

	if line.match(/.*\:#{@nick}[\,\:\ ]+.*/) then
		params = line[/.*\:#{@nick}[\,\:\ ]+(.*)/, 1]
		case
		when params.match(/^join\ \#[\-\_\.\'0-9a-zA-Z]+/)
			channel_to_join = params[/^join\ (\#[\-\_\.\'0-9a-zA-Z]+)/, 1]
			join_chan(channel_to_join)
		when params.match(/^leave/)
	  	if @chan == @userposting
			  sendchn("Say it in the channel you want me to leave.")
		  else
					leave_chan(@chan)
			end
		when params.match(/^[\-\_\.\'\.0-9a-zA-Z]*\ is\ .*/)
			word_to_define = params[/([\-\_\.\'0-9a-zA-Z]*)\ is/, 1]
			definition = params[/[\-\_\ \.\'0-9a-zA-Z]*\ is\ (.*)/, 1]
			add_definition(word_to_define, definition, @userposting)
		when params.match(/^[\-\_\.0-9a-zA-Z]*\?/)
			if !Definitions.count.zero?
        word_to_echo_def = params[/([\-\_\.0-9a-zA-Z]*)?/, 1]
			  echo_definition_by_word(word_to_echo_def)
      end
		when params.match(/^forget\ [\-\_\ 0-9a-zA-Z]*/)
			word_to_forget = params[/forget\ ([\-\_\ 0-9a-zA-Z]*)/, 1]
			forget_definition(word_to_forget)
		when params.match(/^addquote.*/)
			user_to_quote = line[/addquote\ ([0-9a-zA-Z\-\_\.\|]+)\ .*/, 1]
			new_quote = line[/addquote\ [0-9a-zA-Z\-\_\.\|]+\ (.*)/, 1]
			addquote(@userposting, user_to_quote, new_quote)				
		when params.match(/^quote.*/)
      if params.match(/quote\ [0-9]+$/)
	  	  echo_quote_by_id(params[/quote\ (.*)/, 1])
      elsif params.match(/quote\ [a-zA-Z0-9\.\_\-\|]+/)
        echo_quote_by_user(params[/quote\ (.*)/, 1])
      else
        echo_random_quote(@chan) 
		  end
		when params.match(/^rank.*/)
			if params.eql?("rank")
				rank("all")
			elsif params.match("rank\ [a-zA-Z0-9\.\-\_\|]+")
				user_to_rank = params[/rank\ (.*)/, 1]
				rank(user_to_rank)
			end
		when params.eql?("time")
			time = Time.new
			timenow = time.inspect
			sendchn("The current time is #{timenow}")
		when params.eql?("weather")
			# Yahoo Weather Variables
      yahoo_url = 'http://query.yahooapis.com/v1/public/yql?format=json&q='
      query = "SELECT * FROM weather.forecast WHERE location = 27606"
      url = URI.encode(yahoo_url + query)
      # Pull and parse data
      weather_data = JSON.parse(open(url).read)
      weather_results = weather_data["query"]["results"]["channel"]
      sendchn("------------------Weather For 27606---------------")
			sendchn("Current conditions: #{weather_results["wind"]["chill"]} degrees and #{weather_results["item"]["forecast"][0]["text"]}")
      sendchn("Windspeed: #{weather_results["wind"]["speed"]}mph")
      sendchn("High: #{weather_results["item"]["forecast"][0]["high"]} degrees")
      sendchn("Low: #{weather_results["item"]["forecast"][0]["low"]} degrees")
      sendchn("-----------------------------------------------------------")
			
			when params.match(/^help.*/)
        case 
        when  params.eql?("help")
          sendchn("#{@nick}: help [command]")
					sendchn("#{@nick}: <noun> is <definition>")
					sendchn("#{@nick}: <noun>?")
          sendchn("#{@nick}: addquote <name> <quote WITHOUT \"\">")
          sendchn("#{@nick}: quote [name]")
          sendchn("<name>++")
          sendchn("<name>--")
					sendchn("#{@nick} rank")
					sendchn("#{@nick} rank <name>")
          sendchn("#{@nick}: time")
          sendchn("#{@nick}: weather")
					sendchn("#{@nick}: leave")
					sendchn("#{@nick}: join <#channel>")                                        
        when params.eql?("help addquote")
          sendchn("Usage: #{@nick}: addquote <name> <quote WITHOUT \"\">")
          sendchn("Adds a quote to the quote database")
          sendchn("Quotes can be recalled with #{@nick}: quote [name]")                                    when params.eql?("help quote")
          sendchn("Usage: #{@nick}: quote [name]")
          sendchn("Returns a quote from the quote database")
          sendchn("If no name is supplied, a random quote will be returned")                               when params.eql?("help time")
          sendchn("I don't know why you want help with this one #{@userposting}...")
          sendchn("It was more of a way to test getting the time")
          sendchn("Eventually, the time will be used for other commands")                                  when params.eql?("help weather")
          sendchn("PLACEHOLDER")                               
        end
			end
		else
      puts line
			case
			# This one is super important
			# It makes sure swagbot doesn't get disconnected
			when line.match(/^PING :(.*)$/)
				send "PONG #{$~[1]}"

			# Accept invites to channels
			when line.match(/\ INVITE #{@nick}\ \:\#.*/)
				invited_channel = line[/#{@nick}\ \:(\#.*)/, 1]
				join_chan(invited_channel)
				sendchn("I was invited here by #{@userposting}. If I am not welcome type \"#{@nick} leave\"")
			
			# Karma assignments
			when line.match(/^.*[\-\.\'\.\|0-9a-zA-Z]+[\+\-]{2}.*/)
				if @chan != @userposting
					line.split.each do |x| 
						if x.match(/[\-\.\'\.\|0-9a-zA-Z]+\+\+/)
							user = x[/([\-\.\'\.\|0-9a-zA-Z]*)\+\+/, 1]
							if user == @userposting
								sendchn("Lol, yeah right.")
							else
								editkarma(@userposting, user, "add")
							end
						end
						if x.match(/[\-\.\'\.\|0-9a-zA-Z]+\-\-/)
							user = x[/([\-\.\'\.\|0-9a-zA-Z]*)\-\-/, 1]
							if user == @userposting
								sendchn("#{@userposting}, you okay? I'm not going to let you subtract karma from yourself.")
							else
								editkarma(@userposting, user, "subtract")
							end
						end
					end
				else
					sendchn("Karma can only be assigned in a channel")
				end
      when line.match(/.*\:[\-\.\'\.\|0-9a-zA-Z]+\?$/)
        word_to_echo_def = line[/([\-\_\.0-9a-zA-Z]*)\?/, 1]
        echo_definition_by_word(word_to_echo_def)

      when line.match(/.*#{@nick}\ \:\!op$/)
          send("MODE #{@chan} +o #{@userposting}")        
      
      when line.match(/.*http[s]*:\/\/[w\.]*bugzilla\.redhat\.com\/show_bug.cgi\?id=[a-zA-Z0-9]+[\ ]*/)
        url = line[/.*(http[s]*:\/\/[w\.]*bugzilla\.redhat\.com\/show_bug.cgi\?id=[a-zA-Z0-9]+)[\ ]*/, 1]
        bugzilla(url)

      when line.match(/.*http[s]*:\/\/[w\.]*youtube.com\/watch.*/)
        url = line[/.*(http[s]*:\/\/[w\.]*youtube.com\/watch\?v=[a-zA-Z0-9\-\_]+)[\ ]*/, 1]
        youtube(url)
      
      when line.match(/.*http[s]*:\/\/[i\.]*imgur.com\/gallery\/.*/)
        url = line[/.*(http[s]*:\/\/[i\.]*imgur.com\/gallery\/[a-zA-Z0-9\-\_]+).*/, 1]
        imgur(url)

      when line.match(/.*http[s]*:\/\/[i\.]*imgur.com\/.*/)
        url = line[/.*(http[s]*:\/\/[i\.]*imgur.com\/[a-zA-Z0-9\-\_]+).*/, 1]
        imgur(url)
      when line.match(/.*\!http\ [1-5]{1}[0-9]{2}/)
        url = line[/.*\!http\ ([1-5]{1}[0-9]{2})/, 1]
        sendchn("http://httpstatusdogs.com/" + url)
			end
	end
	return nil
end

# Anything after this will be ignored
end
