require 'lifx'
class Greenlights

	@@name		= "Greenlights"
	@@version	= "1.0"
	@@description	= "This application provides a smart lighting system for TerraMod"

	def self.install_tables(db)
		db.execute "CREATE TABLE lights(id INTEGER PRIMARY KEY, 
										label TEXT, 
										credits INTEGER
										);"
		
		db.execute "CREATE TABLE profiles(id INTEGER PRIMARY KEY,
			 							  name TEXT
										  );"
								  
		db.execute "CREATE TABLE rules(id INTEGER PRIMARY KEY,
									   name TEXT,
									   start_time INTEGER,
									   end_time INTEGER,
									   color TEXT,
									   credits INTEGER
									   );"
									   
		db.execute "CREATE TABLE rule_light_junction(rule_id integer,
													 light_id integer,
													 FOREIGN KEY(rule_id) REFERENCES rules(id) ON DELETE CASCADE,
													 FOREIGN KEY(light_id) REFERENCES lights(id) ON DELETE CASCADE
													 );"
									   
		db.execute "CREATE TABLE rule_profile_junction(rule_id INTEGER, 
													   profile_id INTEGER, 
													   FOREIGN KEY(rule_id) REFERENCES rules(id) ON DELETE CASCADE, 
													   FOREIGN KEY(profile_id) REFERENCES profiles(id) ON DELETE CASCADE
													   );"
									   
		db.execute "CREATE TABLE rule_callback_junction(rule_id INTEGER,
														callback_uuid TEXT,
														FOREIGN KEY(rule_id) REFERENCES rules(id) ON DELETE CASCADE
														);"
		
		db.execute "CREATE TABLE active_profile(profile INTEGER,
												FOREIGN KEY(profile) REFERENCES profiles(id)
												);"
												
		#Active profile business assumes the profile in the first position is always the active one, so alter it accordingly
		db.execute("INSERT INTO active_profile(profile) VALUES(null);")
		modules = db.execute("SELECT uuid FROM Modules;")
		add_callbacks(db, modules)
	end

	def self.remove_tables(db)
		# Drop all tables created by the app
		db.execute "DROP TABLE IF EXISTS lights;"
		db.execute "DROP TABLE IF EXISTS profiles;"
		db.execute "DROP TABLE IF EXISTS rules;"
		db.execute "DROP TABLE IF EXISTS active_profile;"
		db.execute "DROP TABLE IF EXISTS rule_profile_junction;"
		db.execute "DROP TABLE IF EXISTS rule_callback_junction;"
		db.execute "DROP TABLE IF EXISTS rule_light_junction;"
	end
	
	def self.callback(db, uuid, data)
		active_profile = db.execute "SELECT profile FROM active_profile;"
		# Get the rules in the active profile
		rules = db.execute("SELECT rule_profile_junction.rule_id FROM rule_profile_junction WHERE profile_id=? INTERSECT 
									SELECT rule_callback_junction.rule_id FROM rule_callback_junction WHERE callback_uuid=?", [active_profile, uuid])
		rules.each do |rule_id|
			if(is_time?(db, rule_id))
				resolve(db, rule_id)
			end
		end
	end
	
	def self.add_rule(db, params)
		begin
			db_file = "/home/josh/Documents/TerraModterramod.db"
			database = SQLite3::Database.open(db_file)
			name = params["name"]
			return "no name set" if name == ''
			callbacks = params["sensor"]
			return "no sensors" if callbacks == ''
			start = params["start"]
			return "no start time" if start == ''
			ending = params["end"]
			return "no end time" if ending == ''
			credits = params["credits"]
			return "no credits" if credits == ''
			color = params["color"]
			return "no color" if color == ''
			lights = params["lights"]
			return "no lights" if lights == ''
			db.execute("INSERT INTO rules(name, start_time, end_time, color, credits) VALUES(?, ?, ?, ?, ?);", 
				[name, start, ending, color, credits])
			rule_id = db.execute "select last_insert_rowid();"
			callbacks.each do |callback|
				db.execute("INSERT INTO rule_callback_junction VALUES(?,?);", [rule_id[0][0], callback])
			end
			lights.each do |light|
				light_id = db.execute("SELECT id FROM lights where label=?;", light).flatten
				db.execute("INSERT INTO rule_light_junction VALUES(?,?);", [rule_id[0][0], light_id])
			end
			db.execute("INSERT INTO rule_profile_junction VALUES(?,?);", [rule_id[0][0], -1])
			database.close
		rescue SQLite3::Exception => e
			puts e
			database.close if database
		end
	end

	def self.remove_rule(db, params)
		id = params["id"]
		begin
			db.execute("DELETE FROM rules WHERE id=?;", [id])
		rescue SQLite3::Exception => e
			puts e
		end
	end
	
	def self.resolve(db, rule_id)
		data = db.execute("SELECT color, credits FROM rules WHERE id=?;", rule_id)
		color_data = data[0][0]
		
		credits = data[0][1]
		light_ids = db.execute("SELECT light_id FROM rule_light_junction WHERE rule_id=?;", rule_id).flatten
		p light_ids
		lifx = LIFX::Client.lan
		lifx.discover!

		case color_data.strip
		when "Red"
			color = LIFX::Color.red(saturation: 0.4)
		when "Orange"
			color = LIFX::Color.orange(saturation: 0.4)
		when "Blue"
			color = LIFX::Color.blue(saturation: 0.4)
		when "Yellow"
			color = LIFX::Color.yellow(saturation: 0.4)
		when "Green"
			color = LIFX::Color.green(saturation: 0.4)
		when "White"
			color = LIFX::Color.white
		when "Purple"
			color = LIFX::Color.purple(saturation: 0.4)
		else
			color = LIFX::Color.white
		end
		
		light_ids.each do |id|
			light_info = db.execute("SELECT label, credits FROM lights WHERE id=?;", id)
			light_label = light_info[0][0]
			light_credits = light_info[0][1]
			
			lights = lifx.lights.with_label(light_label)

			if(credits >= light_credits || credits == -1)
				begin
					lights.set_color(color, duration: 5)
					lights.turn_on!
				rescue
					lights.set_color(color, duration: 5)
				ensure
					db.execute("UPDATE lights SET credits=? WHERE id=?;", [credits, light_ids])
				end
			elsif(credits == 0)
				db.execute("UPDATE lights SET credits=? WHERE id=?;", [credits, light_ids])
				begin
					lights.turn_off!
				rescue
				end
			end
		end
		
	end
	
	# Given the start and stop times for a rule, determine if it's time to do it
	def self.is_time?(db, rule_id)
		times = db.execute("SELECT start_time, end_time FROM rules WHERE id=?", rule_id)
		start = times[0][0]
		finish = times[0][1]
		now = Time.now
		now_hour = now.hour*60*60
		now_min = now.min*60
		now_sec = now.sec
		now = now_hour + now_min + now_sec
		
		if(start > finish)
			start = start - (24*60*60)
		end
		return (now >= start && now <= finish)
	end

	def self.get_rules(db, params)
		profile_id = params["id"]
		return "" if profile_id == ''
		
		rule_ids = db.execute("SELECT rule_id FROM rule_profile_junction WHERE profile_id=?;", profile_id).flatten
		current_rules = []
		unassociated_rules = []
		rule_ids.each do |rule_id|
			current_rules << db.execute("SELECT id, name FROM rules WHERE id=?", rule_id)
		end
		unassociated_ids = db.execute("SELECT rule_id FROM rule_profile_junction WHERE profile_id!=?;", profile_id).flatten
		unassociated_ids.each do |id|
			unassociated_rules << db.execute("SELECT id, name FROM rules WHERE id=?", id)
		end
		p unassociated_rules
		return JSON.dump({"current_rules"=>current_rules,"unassociated_rules"=>unassociated_rules})
	end
	
	def self.add_profile(db, params)
		name = params["name"]
		db.execute("INSERT INTO profiles(name) VALUES(?);", name)
	end
	
	def self.remove_profile(db, id)
		db.execute("DELETE FROM profiles WHERE id=?;", id)
	end

	def self.update_profile(db, params)
		profile_id = params["profile"]
		rules = params["rules"]
		db.execute("DELETE FROM rule_profile_junction WHERE profile_id=?;", profile_id)
		not_rules.each do |rule|
			db.execute("INSERT INTO rule_profile_junction VALUES(?,?);", [rule, profile_id])
		end
	end

	def self.add_light(db, label)
		db.execute("INSERT INTO lights(label, credits) VALUES(?,?);", [label, 0])
	end
	
	def self.remove_light(db, id)
		db.execute("DELETE FROM lights WHERE id=?;", id)
	end
	
	def self.set_active_profile(db, params)
		id = params["profile"]
		db.execute("UPDATE active_profile SET profile=?;", id)
	end
	
	def self.add_callbacks(db, modules)
		modules.each do |uuid|
			db.execute("INSERT INTO Callbacks Values(?,?,?,?);", [uuid, "\\w+", "Greenlights", "callback"])
		end
	end
	
	def self.routes
		return[
				{
						:verb => "post",
						:url => "add_profile",
						:method => Greenlights.method(:add_profile)
				},
				{
						:verb => "post",
						:url => "profiles/:id",
						:method => Greenlights.method(:update_profile)
				},
				{
						:verb => "post",
						:url => "remove_profile",
						:method => Greenlights.method(:remove_profile)
				},
				{
						:verb => "get",
						:url => "rules/:id",
						:method => Greenlights.method(:get_rules)
				},
				{
						:verb => "post",
						:url => "remove_rule",
						:method => Greenlights.method(:remove_rule)
				},
				{
						:verb => "post",
						:url => "add_rule",
						:method => Greenlights.method(:add_rule)
				},
				{
						:verb => "post",
						:url => "set_active",
						:method => Greenlights.method(:set_active_profile)
				}
			]
	end
end
