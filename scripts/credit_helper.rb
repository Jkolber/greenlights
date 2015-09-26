#!/usr/bin/env ruby
require 'sqlite3'
require 'lifx'

begin
	lifx = LIFX::Client.lan
	lifx.discover!
	
	#requires absolute filepath to db
	db = SQLite3::Database.open('/home/pi/TerraMod/terramod.db')
	db.execute('UPDATE Lights SET credits=credits-1 WHERE credits>0;');
	labels = db.execute('SELECT label FROM Lights where credits<=0;')
	labels.each do |label|
		puts "#{Time.now}: label: #{label[0]}"
		lights = lifx.lights.with_label(label[0])
		puts "#{Time.now}: lights: #{lights}"
		lights.turn_off!
	end
	db.close if db
rescue SQLite3::Exception => e
	chdir('../logs')
	open('credit.log', 'a') do |log|
		log.puts "#{Time.now}: "
		log.puts e
		log.puts "\n"
	end
	db.close if db
end
