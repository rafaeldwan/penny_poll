# penny_poll.rb

require 'sinatra'
require 'sinatra/reloader' if development?
require 'sinatra/content_for'
require 'tilt/erubis'
require 'yaml'
require 'bcrypt'
require 'google_drive'
require 'securerandom'
require 'time'
require 'chartkick'
include Chartkick::Helper

# Fixes SSL Connection Error in Windows execution of Ruby
# Based on fix described at: https://gist.github.com/fnichol/867550
ENV['SSL_CERT_FILE'] = Dir.pwd + '/cacert.pem' if Gem.win_platform?

# Set to "false" to disable remote data storage.
# WARNING - local data will be overwritten when set back to true
USE_GOOGLE_DRIVE = true

# google_session - this app can connect to Google Drive to store
# the files users.yaml and polls.yaml
# you'll need your own google_service_account_credential_file
# which means you'll need copies of those file in a google drive
# you have access to and you'll need to set up some stuff in your
# Google dev console as detailed here:
# https://github.com/gimite/google-drive-ruby/blob/master/doc/authorization.md#on-behalf-of-no-existing-users-service-account
def google_session
  google_service_account_credential_file = 'pennypoll-d23e19e91329.json'

  GoogleDrive::Session.from_service_account_key(
    google_service_account_credential_file
  )
end

# opens file based on environment, parses YAML, returns hash
def read_data(file)
  if ENV['RACK_ENV'] == 'test'
    local = File.expand_path("../test/data/#{file}", __FILE__)
  else
    local = File.expand_path("../data/#{file}", __FILE__)

    if USE_GOOGLE_DRIVE
      remote = google_session.file_by_title(file.to_s)
      remote.download_to_file(local)
    end
  end

  YAML.load_file(local)
end

# returns polls hash
def read_polls_data
  read_data('polls.yaml')
end

# returns user hash
def read_user_data
  read_data('users.yaml')
end

# saves data based on environment
def save_data(file, data)
  if ENV['RACK_ENV'] == 'test'
    local = File.expand_path("../test/data/#{file}", __FILE__)
    File.open(local, 'w') { |open_file| open_file.write(YAML.dump(data)) }
  else
    local = File.expand_path("../data/#{file}", __FILE__)
    File.open(local, 'w') { |open_file| open_file.write(YAML.dump(data)) }

    if USE_GOOGLE_DRIVE
      remote = google_session.file_by_title(file.to_s)
      remote.update_from_file(local)
    end
  end
end

# save user hash to file
def save_user_data(data)
  save_data('users.yaml', data)
end

# save polls hash to file
def save_polls_data(data)
  save_data('polls.yaml', data)
end

def generate_uuid
  SecureRandom.uuid
end

# User has an id, vote history, permissions, can vote, login, logoff
class User
  attr_reader :username, :id, :votes

  def initialize(user_id)
    users = read_user_data

    @id = user_id
    our_guy = users.fetch(@id)

    @username = our_guy[:username]
    @votes = our_guy[:votes]
  end

  # creates and stores new user
  def self.create(username, password)
    users = read_user_data

    id = generate_uuid
    hashed_password = User.hash_password(password)
    created = Time.new

    users[id] = { username: username.strip, password: hashed_password,
                  created: created, votes: {} }

    save_user_data(users)
  end

  # returns user creation error string
  def self.creation_error(username, pass1, pass2)
    if username_taken?(username)
      'Sorry, that name has already been taken.'
    elsif !(1..20).cover?(username.size)
      'Name must be between 1 and 20 characters.'
    elsif pass1 != pass2
      'Passwords must match. Please re-enter.'
    elsif pass1.size < 5
      'Passwords must be at least 5 characters'
    end
  end

  # returns encrypted password
  def self.hash_password(password)
    BCrypt::Password.create(password).to_s
  end

  # preps and records vote data to users.yaml and polls.yaml
  def vote(poll_id, poll_name, votes)
    users = read_user_data

    users[@id][:votes][poll_id] = {
      name: poll_name,
      timestamp: Time.new,
      votes: {}
    }

    final_polls, final_users = prepare_votes_data(users, votes, poll_id)

    save_polls_data(final_polls)
    save_user_data(final_users)
  end

  # verifies U and P
  def self.valid_credentials?(username, password)
    users = read_user_data

    if username_taken?(username, users)
      user = users.find { |_, value| value[:username] == username }[1]

      hashed_p = BCrypt::Password.new user[:password]
      hashed_p && hashed_p == password
    else
      false
    end
  end

  # checks if username is available
  def self.username_taken?(username, users = read_user_data)
    users.any? { |_, value| value[:username] == username }
  end

  # looks up user id associated with a username. Needed for setting
  # session[:user_id] following new user creation.
  def self.get_id(username)
    users = read_user_data
    users.find { |_, value| value[:username] == username }[0]
  end

  # returns an array of user's vote, delete, and/or reset permissions for passed
  # poll
  def permissions(poll_path, polls = read_polls_data)
    poll = Poll.new(poll_path, polls)

    permissions = []

    permissions.push('vote') unless votes[poll.id]
    permissions.push('delete') if can_delete?(poll)
    permissions.push('reset') if username == 'admin'

    permissions
  end

  private

  # loops through passed votes and records to user and poll hashes,
  # returns updated user and poll hashes to public `vote` method
  def prepare_votes_data(users, votes, poll_id)
    polls = read_polls_data

    votes.each do |option, vote|
      vote = vote.to_i
      users[@id][:votes][poll_id][:votes][option] = vote

      next if vote.zero?
      polls[poll_id][:options][option] += vote
    end

    [polls, users]
  end

  # helper method for permissions. returns true if current user can delete
  # poll
  def can_delete?(poll)
    poll.author == id || username == 'admin'
  end
end

# Polls have a number of readable characteristics and methods
# which return useful information such as total vote count
# can be created, deleted, and reset
class Poll
  attr_reader :options, :id, :name, :max_votes, :author, :description, :path

  def initialize(path, polls = read_polls_data)
    @path = path
    @id = polls.find { |_, poll| poll[:path] == @path }[0]

    poll = polls.fetch(@id)

    @name = poll[:name]
    @options = poll[:options]
    @max_votes = poll[:votes_per_user]
    @author = poll[:author]
    @description = poll[:description]
  end

  # returns numbers of votes cast for calling poll
  def vote_count
    options.values.reduce(:+)
  end

  # creates and saves new poll, returns path
  def self.create(name, votes_per_user, author_id, description, options)
    id = generate_uuid
    created = Time.new
    polls = read_polls_data

    path = create_poll_path(name, polls)

    options = options.each_with_object({}) { |opt, hsh| hsh[opt[1].strip] = 0 }

    polls[id] = { name: name.strip, path: path, author: author_id,
                  created: created, votes_per_user: votes_per_user.to_i,
                  description: description.strip, options: options }

    save_polls_data(polls)
    path
  end

  # returns usuable URL for new poll based on name. strips whitespace,
  # removes /\W/ characters, replaces spaces with underscores,
  # downcases, checks for existing path and appends appropriate number if found
  def self.create_poll_path(name, polls)
    path = name.strip
    path = path[0, 20] if path.size > 20
    path.downcase!

    path.gsub!(/[^\w\s]/, '')
    path.gsub!(/\s+/, '_')

    path = dupe_path_adjust(path, polls)

    path
  end

  # helper for #create_poll_path, returns path adjusted for dupes
  def self.dupe_path_adjust(path, polls)
    adjustment = 1
    og_path = path
    until polls.none? { |poll| poll[1][:path] == path }
      path = "#{og_path}_#{adjustment}"
      adjustment += 1
    end
    path
  end

  # returns poll creation error string
  def self.creation_error(name, max_votes, options)
    if wrong_size?(name)
      'Sorry, poll name must be between 1 and 150 characters.'
    elsif max_votes.to_i < 3
      'Sorry, you must give users at least 3 votes.'
    elsif options.any? { |option| wrong_size?(option) }
      'Sorry, option names must be between 1 and 150 characters.'
    elsif options.size < 3
      'Sorry, polls must have at least 3 options.'
    elsif options.map(&:strip).uniq.size != options.size
      'Sorry, all option names must be unique.'
    end
  end

  # helper for user creation error, checks length of string
  def self.wrong_size?(string)
    !(1..150).cover?(string.length)
  end

  # deletes a poll. USER VOTE RECORDS FOR DELETED POLLS ARE PRESERVED
  def delete!
    polls = read_polls_data
    polls.delete(id)
    save_polls_data(polls)
  end

  # resets all votes for calling poll to 0. ALSO RESETS ALL USER VOTE RECORDS
  # FOR CALLING POLL
  def reset!
    polls = read_polls_data
    users = read_user_data

    polls, users = process_reset(polls, users)

    save_polls_data(polls)
    save_user_data(users)
  end

  # returns error message string if votes cast != votes required
  def self.error_voting(cast_votes, max)
    if cast_votes > max
      "You cast #{cast_votes} votes. You can't cast more than #{max} votes!"
    elsif cast_votes < max
      "You used #{cast_votes} votes. Please use all #{max} of your votes!"
    end
  end

  private

  # helper for #reset! returns reset users and polls hashes
  def process_reset(polls, users)
    options.each do |key, _|
      polls[id][:options][key] = 0
    end

    users.each do |user|
      user[1][:votes].delete(id) if user[1][:votes][id]
    end

    [polls, users]
  end
end

### BEGIN SINATRA

configure do
  enable :sessions
  set :session_secret, 'secret'
  set :erb, escape_html: true
end

helpers do
  # returns true if user is signed in
  def signed_in?
    session[:user_id]
  end

  # gets user's permissions for passed-in poll, returns empty array
  # if no current user
  def get_permissions(poll_path, polls = read_polls_data)
    if signed_in?
      @user.permissions(poll_path, polls)
    else
      []
    end
  end

  # last real programming I did for this app. This was a horrible mess of
  # nested conditionals in two different views and is poetry compared to what
  # it was.
  # Constructs an HTML string of links and buttons based on the user's
  # permissions for the passed-in poll.
  def build_actions(path, polls = read_polls_data)
    permissions = get_permissions(path, polls)
    vote_link = "<a href = \"/polls/#{path}/vote\">Vote</a>"

    delete_button = get_delete_button(path)
    reset_button = get_reset_button(path)

    actions = ''
    actions += " #{vote_link}" if permissions.include?('vote')
    actions += " #{delete_button}" if permissions.include?('delete')
    actions += " #{reset_button}" if permissions.include?('reset')

    actions
  end

  # generates HTML delete button string
  def get_delete_button(path)
    <<-HEREDOC
<form class="inline delete" method="post" action="/polls/#{path}/delete" >
  <button class="delete" type="submit">Delete</button>
</form>
    HEREDOC
  end

  # generates HTML reset button string
  def get_reset_button(path)
    <<-HEREDOC
<form class="inline reset" method="post" action="/polls/#{path}/reset" >
  <button class="reset" type="submit">Reset</button>
</form>
    HEREDOC
  end
end

before do
  @user = User.new(session[:user_id]) if signed_in?
end

get '/' do
  redirect '/polls'
end

# homescreen, shows list of polls each with available actions (view results,
# vote, delete, reset). Has create poll link if appropriate.
get '/polls' do
  @polls = read_polls_data
  erb :index
end

# individual results page including pie chart. shows available actions.
get '/polls/:poll/results' do
  @permissions = get_permissions(params[:poll])
  @poll = Poll.new(params[:poll])
  @chart_data = @poll.options.map { |name, votes| [name, votes.to_s] }

  erb :poll_results
end

# vote page for each poll
get '/polls/:poll/vote' do
  @permissions = get_permissions(params[:poll])
  @poll = Poll.new(params[:poll])

  if signed_in? && @permissions.include?('vote')
    erb :poll_vote
  else
    redirect "/polls/#{params[:poll]}/results"
  end
end

# process votes
post '/polls/:poll/vote' do
  @poll = Poll.new(params[:poll])
  permissions = get_permissions(@poll.path)

  if !signed_in? || !permissions.include?('vote')
    redirect '/polls/#{params[:poll]/results'
  end

  cast_votes = params[:votes].values.map(&:to_i).reduce(:+)

  error = Poll.error_voting(cast_votes, @poll.max_votes)
  if error
    session[:error] = error
    status 422
    erb :poll_vote
  else
    @user.vote(@poll.id, @poll.name, params[:votes])
    session[:success] = 'Your votes have been recorded!'
    redirect "/polls/#{params[:poll]}/results"
  end
end

# user signup form
get '/user/new' do
  erb :new_user
end

# process new user
post '/user/new' do
  username = params[:username].strip

  error = User.creation_error(username, params[:pass1], params[:pass2])
  if error
    status 422
    session[:error] = error
    erb :new_user
  else
    User.create(username, params[:pass1])
    session[:user_id] = User.get_id(username)
    session[:success] = 'Account created. Welcome new user!'
    redirect '/polls'
  end
end

# sign out user
post '/user/logout' do
  session.delete(:user_id)
  session[:success] = 'You have been signed out. Bye!'
  redirect '/polls'
end

# sign in form
get '/user/login' do
  if signed_in?
    session[:error] = 'You are already logged in.'
    redirect '/'
  end

  erb :log_in
end

# process sign in
post '/user/login' do
  username = params[:username]

  if User.valid_credentials?(username, params[:password])
    session[:user_id] = User.get_id(username)
    session[:success] = "Welcome, #{username}! Hang out a while!"
    redirect '/'
  else
    session[:error] = 'Invalid Credentials.'
    status 422
    erb :log_in
  end
end

# new poll form
get '/polls/new' do
  if signed_in?
    @number_of_options = 4
    erb :new_poll
  else
    session[:error] = 'You must be signed in to create a poll.'
    redirect '/'
  end
end

# process new poll
post '/polls/new' do
  if signed_in?
    name = params[:name].strip
    max_votes = params[:votes_per_user]
    description = params[:description].strip
    options = params[:options].map { |option| option[1].strip }

    error = Poll.creation_error(name, max_votes, options)

    if error
      session[:error] = error
      @number_of_options = options.size
      status 422
      erb :new_poll
    else
      new_poll = Poll.create(name, max_votes, @user.id, description,
                             params[:options])
      session[:success] = 'Your new poll was created!'
      redirect "/polls/#{new_poll}/results"
    end

  else
    session[:error] = 'You must be signed in to create a poll.'
    redirect '/'
  end
end

# regenerate poll submission form with different number of options
post '/polls/new/add_options' do
  if signed_in?
    @number_of_options = params[:number_of_options].to_i
    erb :new_poll
  else
    session[:error] = 'You must be signed in to create a poll.'
    redirect '/'
  end
end

# delete poll
post '/polls/:poll/delete' do
  @permissions = get_permissions(params[:poll])
  if !signed_in? || !@permissions.include?('delete')
    session[:error] = "You can't do that."
    redirect '/'
  end

  Poll.new(params[:poll]).delete!
  session[:success] = 'Poll has been deleted.'

  if env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'
    '/'
  else
    redirect '/'
  end
end

# reset poll
post '/polls/:poll/reset' do
  @permissions = get_permissions(params[:poll])

  if !signed_in? || !@permissions.include?('reset')
    session[:error] = "You can't do that."
    redirect '/'
  end

  Poll.new(params[:poll]).reset!
  session[:success] = 'Poll has been reset.'

  if env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'
    '/'
  else
    redirect '/'
  end
end

# redirect polls/"some_poll"/ page to polls/"some_poll"/results page
get '/polls/:poll' do
  redirect "/polls/#{params[:poll]}/results"
end
