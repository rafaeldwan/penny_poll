# tests/penny_test.rb
ENV['RACK_ENV'] = 'test'

require 'simplecov'
SimpleCov.start

require 'minitest/autorun'
require 'rack/test'

require 'minitest/reporters'

Minitest::Reporters.use!

require_relative '../penny_poll'

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def session
    last_request.env['rack.session']
  end

  def app
    Sinatra::Application
  end

  def admin_session
    { 'rack.session' => { user_id: "b50ae6e-a4d2-42c3-a1de-6a3faf5eef0c" } }
  end

  def user_session
    { 'rack.session' => { user_id: "1ec98d39-1ef1-483c-8c7e-1bcca7f98314" } }
  end

  def setup
    @polls = read_polls_data
    @users = read_user_data
  end

  def teardown
    save_polls_data(@polls)
    save_user_data(@users)
  end

  def test_index_redirect
    get '/'
    assert_equal 302, last_response.status
  end

  def test_page_polls
    get '/polls'
    assert_equal 200, last_response.status

    assert_includes last_response.body, "Government Budget"
    assert_includes last_response.body, "login"
  end

  def test_page_polls_logged_in
    get '/polls', {}, user_session
    assert_includes last_response.body, "vote"
  end

  def test_page_polls_admin
    get '/polls', {}, admin_session
    assert_includes last_response.body, "reset"
  end

  def test_poll_results_page
    get '/polls/government_budget/results'
    assert_includes last_response.body, "Results for \"Government Budget\""
    assert_includes last_response.body, "education: 28"
    assert_includes last_response.body, "100 votes cast by 10 users"

    # need javascript chart test
  end

  def test_poll_results_page_author
    get '/polls/rate_the_animals/results', {}, user_session
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Delete"
  end

  def test_poll_results_page_admin
    get '/polls/wow_a_long_name_wi/results', {}, admin_session
    assert_includes last_response.body, "Reset"
  end

  def test_poll_results_page_short_url_redirect
    get '/polls/government_budget'
    assert_equal last_response.status, 302
    follow_redirect!
    assert_includes last_response.body, "education: 28"
  end

  def test_poll_vote_page_log_out_redirect
    get '/polls/government_budget/vote'
    assert_equal 302, last_response.status
  end

  def test_vote_page_voted_redirect
    get '/polls/government_budget/vote', {}, user_session
    assert_equal 302, last_response.status
  end

  def test_vote_page
    get '/polls/wheres_waldo/vote', {}, user_session
    assert_equal 200, last_response.status
    assert_includes last_response.body, "input name=\"votes[Ancient Rome]"
  end

  def test_vote_process
    post '/polls/best_decade/vote', {votes:{'1990s' => '5'}}, user_session

    assert_equal 302, last_response.status
    assert_equal 'Your votes have been recorded!', session[:success]
    follow_redirect!
    assert_includes last_response.body, '5 votes cast by 1 user.'
  end

  def test_vote_process_cant_vote_redirect
    post '/polls/government_budget/vote'
    assert_equal 302, last_response.status
    get '/polls/government_budget/vote', {}, user_session
    assert_equal 302, last_response.status
  end

  def test_vote_count_errors
    post '/polls/best_decade/vote', {votes:{'1990s' => '4', '1960s' => '2'}}, user_session
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'You cast 6 votes.'

    post '/polls/best_decade/vote', {votes:{'1990s' => '3'}}, user_session
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'You used 3 votes.'
  end

  def test_new_user_page
    get '/user/new'
    assert_includes last_response.body, 'Sign Up</button>'
  end

  def test_new_user_signup
    # copies the user file, creates the new user, then restores the file from copy
    post '/user/new', username: 'testy', pass1: 'tests', pass2: 'tests'

    assert_equal 302, last_response.status
    assert_equal 'Account created. Welcome new user!', session[:success]
    follow_redirect!

    assert_includes last_response.body, 'testy'
  end

  def test_new_password_error
    post '/user/new', username: 'testy', pass1: 'test', pass2: 'not the same'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'Passwords must match. Please re-enter.'
    assert_nil session[:user]

    post '/user/new', username: 'testy', pass1: 'aa', pass2: 'aa'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'Passwords must be longer than 5 characters'
    assert_nil session[:user]
  end

  def test_new_user_dupe_username
    post '/user/new', username: 'admin', pass1: 'test', pass2: 'not the same'
    assert_includes last_response.body, 'Sorry, that name has already been taken'
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'admin'
    assert_nil session[:user]
  end

  def test_new_user_empty_username_error
    post '/user/new', username: '    ', pass1: 'tests', pass2: 'tests'
    assert_includes last_response.body, 'Name must be between 1 and 20 characters.'
  end

  def test_new_user_long_username_error
    post '/user/new', username: 'this_should_definitely_be_well_over_20_characters', pass1: 'tests', pass2: 'tests'
    assert_includes last_response.body, 'Name must be between 1 and 20 characters.'
  end

  def test_user_login_page
    get '/user/login'
    assert_includes last_response.body, "<label for=\"username\">"
    get 'user/login', {}, user_session
    assert_equal 302, last_response.status
    assert_equal session[:error], "You are already logged in."
  end

  def test_user_login_process
    post '/user/login', username: "admin", password: "secret"
    assert_equal 'b50ae6e-a4d2-42c3-a1de-6a3faf5eef0c', session[:user_id]
  end

  def test_user_login_error
    post '/user/login', username: "admin", password: "wrong"
    post '/user/login', username: "wrong", password: "secret"
    assert_nil session[:user_id]
    assert_includes last_response.body, "Invalid Credentials"
  end

  def test_user_signout
    post '/user/logout', {}, user_session
    assert_nil session[:user_id]
    assert_equal session[:success], 'You have been signed out. Bye!'
    assert_equal last_response.status, 302
  end

  def test_new_poll_page
    get '/polls/new', {}, user_session
    assert_includes last_response.body, "Update"
  end

  def test_new_poll_page_logged_out
    get '/polls/new'
    assert_equal last_response.status, 302
  end

  def test_new_poll_add_options
    post '/polls/new/add_options', {number_of_options: 5}, user_session
    assert_includes last_response.body, "Option 5 name:"
  end

  def test_new_poll_add_options_logged_out
    post '/polls/new/add_options', {number_of_options: 5}
    assert_equal last_response.status, 302
  end

  def test_new_poll_process
    post '/polls/new', {name: "test! a test! with a long name!",
                        votes_per_user: '3',
                        description: "a fake description",
                        options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade"} },
                        user_session
    assert_equal session[:success], "Your new poll was created!"

    follow_redirect!
    assert_includes last_response.body, "0 votes cast by 0 users."
  end

  def test_new_poll_process_dupe_name
    2.times do
      post '/polls/new', {name: "Government Budget",
                        votes_per_user: '3',
                        description: "a fake description",
                        options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade"} },
                        user_session
      assert_equal session[:success], "Your new poll was created!"
    end
    get '/polls/government_budget_2/results'
    assert_equal 200, last_response.status
  end

  def test_new_poll_process_logged_out
    post '/polls/new', {name: "test! a test! with a long name!",
                        votes_per_user: '3',
                        description: "a fake description",
                        options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade"} }
    assert_equal session[:error], 'You must be signed in to create a poll.'
    assert_equal last_response.status, 302
  end

  def test_new_poll_error_empty_name_and_poll_form_entry_persistence
    post '/polls/new', { name: "    ",
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade", "5" => "PEANUT BUTTER"} },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, 'Sorry, poll name must be between 1 and 150 characters.'
    assert_includes last_response.body, "name=\"options[5]\" type=\"text\"  value=\"PEANUT BUTTER\""
  end

  def test_new_poll_error_name_too_long
    name = "One morning, when Gregor Samsa woke from troubled dreams, he found himself transformed in his bed into a horrible vermin. He lay on his armour-like bac"
    post '/polls/new', { name: name,
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade", "5" => "PEANUT BUTTER"} },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, 'Sorry, poll name must be between 1 and 150 characters.'
  end

  def test_new_poll_error_too_few_options
    post '/polls/new', { name: "bubba",
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam"} },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, 'Sorry, polls must have at least 3 options.'
  end

  def test_new_poll_error_empty_option_name
    post '/polls/new', { name: "bubba",
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => "   " } },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, "Sorry, option names must be between 1 and 150 characters."
  end

  def test_new_poll_error_option_name_too_long
    name = "One morning, when Gregor Samsa woke from troubled dreams, he found himself transformed in his bed into a horrible vermin. He lay on his armour-like bac"
    post '/polls/new', { name: "bubba",
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => name } },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, "Sorry, option names must be between 1 and 150 characters."
  end

  def test_new_poll_error_option_name_dupe
    post '/polls/new', { name: "bubba",
                         votes_per_user: '3',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => "jelly" } },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, "Sorry, all option names must be unique."
  end

  def test_new_poll_error_not_enough_votes
    post '/polls/new', { name: "bubba",
                         votes_per_user: '1',
                         description: "a fake description",
                         options: {"1" => "jelly", "2" => "jam", "3" => "preserves", "4" => "marmalade" } },
                        user_session
    assert_equal last_response.status, 422
    assert_includes last_response.body, "Sorry, you must give users at least 3 votes."
  end

  def test_poll_delete

    get '/polls'
    assert_includes last_response.body, "Rate the animals!"

    post '/polls/rate_the_animals/delete', {}, user_session
    assert_equal last_response.status, 302
    follow_redirect!
    refute_includes last_response.body, "Rate the animals!"
  end

  def test_poll_delete_error_signed_out_not_author
    post '/polls/government_budget/delete'
    assert_equal last_response.status, 302

    post '/polls/government_budget/delete', {}, user_session
    assert_equal last_response.status, 302
    assert_equal session[:error], "You can't do that."
  end

  def test_poll_reset
    get "/polls/government_budget/vote", {}, admin_session
    assert_equal 302, last_response.status

    post '/polls/government_budget/reset'

    assert_equal last_response.status, 302
    assert_equal session[:success], "Poll has been reset."

    get "/polls"
    assert_includes last_response.body, "<strong>Government Budget</strong>\n      <em>0 votes cast</em>"

    get "/polls/government_budget/vote"
    assert_equal 200, last_response.status
  end

  def test_poll_reset_error_signed_out_author
    post '/polls/rate_the_animals/reset'
    assert_equal session[:error], "You can't do that."
    post '/polls/rate_the_animals/reset', {}, user_session
    assert_equal session[:error], "You can't do that."
  end
end
