# frozen_string_literal: true

require "rubygems"
require "optimist"

OPTS = Optimist.options do
  banner <<-TEXT
    Import Sendgrid email suppressions and store locally.
    Usage:
    rails runner tools/sync_sendgrid_suppressions.rb
    where [options] are:
  TEXT
  opt :debug, "Print debug statements", type: :boolean, short: "-d"
end

start = Time.now

def get_response( url )
  RestClient.get( url, {
    "Authorization" => "Bearer #{CONFIG.sendgrid.api_key}"
  } )
end

def get_records( url_base )
  json = [1]
  records = []
  success = true
  i = 0
  while json.count.positive? && success == true
    puts "\t...reading page #{i}"
    offset = 500 * i
    url = "#{url_base}?limit=500&offset=#{offset}"
    begin
      response = get_response( url )
    rescue Timeout::Error
      response = get_response( url )
      begin
        response = get_response( url )
      rescue Timeout::Error
        success = false
      end
    end
    json = JSON.parse( response )
    records << json
    i += 1
  end
  { records: records.flatten, success: success }
end

def get_supressions( suppression_type )
  puts "getting suppressions of type #{suppression_type}"
  url_base = "https://api.sendgrid.com/v3/suppression/#{suppression_type}"
  records = get_records( url_base )
  emails = records[:records].map {| i | i["email"] }.uniq
  { emails: emails, success: records[:success] }
end

def get_supression_group
  puts "getting group suppressions"
  url_base = "https://api.sendgrid.com/v3/asm/suppressions"
  records = get_records( url_base )
  emails = {}
  records[:records].map {| i | i["group_name"] }.uniq.each do | group_name |
    group = records[:records].select {| i | i["group_name"] == group_name }.map {| i | i["email"] }
    emails[group_name.parameterize.underscore] = group
  end
  { emails: emails, success: records[:success] }
end

def save_emails( emails, suppression_type )
  failed_to_save = []
  emails.each do | email |
    es = EmailSuppression.find_or_initialize_by( email: email, suppression_type: suppression_type )
    if es.new_record?
      unless es.save
        failed_to_save << { email: email, suppression_type: suppression_type }
      end
    else
      es.touch
    end
  end
  failed_to_save
end

def work_on_group( suppression_type )
  emails = get_supressions( suppression_type )
  puts "saving suppressions"
  failed_to_save = save_emails( emails[:emails], suppression_type )
  { success: emails[:success], failed_to_save: failed_to_save }
end

successful_groups = []
failed_to_save = []
status = work_on_group( EmailSuppression::BOUNCES )
successful_groups << EmailSuppression::BOUNCES if status[:success]
failed_to_save << status[:failed_to_save]

status = work_on_group( EmailSuppression::INVALID_EMAILS )
successful_groups << EmailSuppression::INVALID_EMAILS if status[:success]
failed_to_save << status[:failed_to_save]

status = work_on_group( EmailSuppression::SPAM_REPORTS )
successful_groups << EmailSuppression::SPAM_REPORTS if status[:success]
failed_to_save << status[:failed_to_save]

status = work_on_group( EmailSuppression::UNSUBSCRIBES )
successful_groups << EmailSuppression::UNSUBSCRIBES if status[:success]
failed_to_save << status[:failed_to_save]

emails = get_supression_group
emails[:emails].each do | st, e |
  failed_to_save << save_emails( e, st )
end
failed_to_save = failed_to_save.flatten.group_by {| record | record[:suppression_type] }

if emails[:success]
  successful_groups << emails[:emails].keys
end
successful_groups = successful_groups.flatten

unsuccessful_groups = EmailSuppression::SUPRESSION_TYPES - successful_groups

create_count = EmailSuppression.where( "updated_at >= ? OR created_at >= ?", start, start ).count

to_remove = EmailSuppression.where( "updated_at < ? AND suppression_type IN (?)",
  start, successful_groups )
remove_count = to_remove.count
if remove_count.positive?
  puts "Removing #{remove_count} here's a sample:"
  to_remove.limit( 50 ).map {| i | puts i.attributes.values.join( " : " ) }
  to_remove.delete_all
end

puts
puts "Imported #{create_count} emails and removed #{remove_count} emails in #{Time.now - start}s"
puts
if unsuccessful_groups.count.positive?
  puts "Syncing unsuccessful for the following group(s): #{unsuccessful_groups.join( ', ' )}"
end
if failed_to_save.count.positive?
  puts "The following emails unsuccessfully saved:"
  failed_to_save.each do | k, v |
    puts "\t#{k}"
    v.each do | row |
      puts "\t\t#{row[:email]}"
    end
  end
end
