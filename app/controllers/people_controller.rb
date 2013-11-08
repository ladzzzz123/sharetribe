require 'rdf'
require 'rdf/ntriples'

class PeopleController < Devise::RegistrationsController
  
  include PeopleHelper
  include RDF
  
  skip_before_filter :verify_authenticity_token, :only => [:creates]
  skip_before_filter :require_no_authentication, :only => [:new]
  
  before_filter :only => [ :update, :destroy ] do |controller|
    controller.ensure_authorized t("layouts.notifications.you_are_not_authorized_to_view_this_content")
  end
  
  before_filter :person_belongs_to_current_community, :only => [:show]
  before_filter :ensure_is_admin, :only => [ :activate, :deactivate ]
  
  skip_filter :check_email_confirmation, :only => [ :update]
  skip_filter :dashboard_only
  skip_filter :single_community_only, :only => [ :create, :update, :check_username_availability, :check_email_availability, :check_email_availability_and_validity, :check_email_availability_for_new_tribe]
  skip_filter :cannot_access_without_joining, :only => [ :check_email_availability_and_validity, :check_invitation_code ]
  
  # Skip auth token check as current jQuery doesn't provide it automatically
  skip_before_filter :verify_authenticity_token, :only => [:activate, :deactivate]
  
  
  helper_method :show_closed?
  
  def index
    @selected_tribe_navi_tab = "members"
    params[:page] = 1 unless request.xhr?
    @people = @current_community.members.order("created_at DESC").paginate(:per_page => 15, :page => params[:page])
    request.xhr? ? (render :partial => "additional_members") : (render :action => :index)
  end
  
  def show
    @selected_tribe_navi_tab = "members"
    @community_membership = CommunityMembership.find_by_person_id_and_community_id_and_status(@person.id, @current_community.id, "accepted")
    @listings = persons_listings(@person)
  end

  def new
    @selected_tribe_navi_tab = "members"
    redirect_to root if logged_in?
    session[:invitation_code] = params[:code] if params[:code]
    @person = Person.new
    
    if params[:person] #if values given in params, set them for the form
      @person.given_name = params[:person][:given_name]
      @person.family_name = params[:person][:family_name]
      @person.email = params[:person][:email]
      @person.username = params[:person][:username]
    end
    @container_class = params[:private_community] ? "container_12" : "container_24"
    @grid_class = params[:private_community] ? "grid_6 prefix_3 suffix_3" : "grid_10 prefix_7 suffix_7"
  end

  def create
    @current_community ? domain = @current_community.full_url : domain = "#{request.protocol}#{request.host_with_port}"
    error_redirect_path = domain + sign_up_path
    
    # special handling for communities that require organization membership
    # deprecated
    if @current_community && @current_community.requires_organization_membership?
      @org_membership_required = true
    else
      @org_membership_required = false
    end
    
    if params[:person][:email_repeated].present? # Honey pot for spammerbots
      flash[:error] = t("layouts.notifications.registration_considered_spam")
      ApplicationHelper.send_error_notification("Registration Honey Pot is hit.", "Honey pot")
      redirect_to error_redirect_path and return
    end
    
    if @current_community && @current_community.join_with_invite_only? || params[:invitation_code]

      unless Invitation.code_usable?(params[:invitation_code], @current_community)
        # abort user creation if invitation is not usable. 
        # (This actually should not happen since the code is checked with javascript)
        session[:invitation_code] = nil # reset code from session if there was issues so that's not used again
        ApplicationHelper.send_error_notification("Invitation code check did not prevent submiting form, but was detected in the controller", "Invitation code error")
        
        # TODO: if this ever happens, should change the message to something else than "unknown error"
        flash[:error] = t("layouts.notifications.unknown_error")
        redirect_to error_redirect_path and return
      else
        invitation = Invitation.find_by_code(params[:invitation_code].upcase)
      end
    end
    
    # Check that email is not taken
    unless Person.email_available?(params[:person][:email])
      flash[:error] = t("people.new.email_is_in_use")
      redirect_to error_redirect_path and return
    end
    
    # Check that the email is allowed for current community
    if @current_community && ! @current_community.email_allowed?(params[:person][:email])
      flash[:error] = t("people.new.email_not_allowed")
      redirect_to error_redirect_path and return
    end
    
    @person = Person.new
    if APP_CONFIG.use_recaptcha && @current_community && @current_community.use_captcha && !verify_recaptcha_unless_already_accepted(:model => @person, :message => t('people.new.captcha_incorrect'))
        
      # This should not actually ever happen if all the checks work at Sharetribe's end.
      # Anyway if Captha responses with error, show message to user
      # Also notify admins that this kind of error happened.
      # TODO: if this ever happens, should change the message to something else than "unknown error"
      flash[:error] = t("layouts.notifications.unknown_error")
      ApplicationHelper.send_error_notification("New user Sign up failed because Captha check failed, when it shouldn't.", "Captcha error")
      redirect_to error_redirect_path and return
    end


    params[:person][:locale] =  params[:locale] || APP_CONFIG.default_locale
    params[:person][:test_group_number] = 1 + rand(4)
    
    # skip email confirmation unless it's required in this community
    params[:person][:confirmed_at] = (@current_community.email_confirmation ? nil : Time.now) if @current_community
    
    params["person"].delete(:terms) #remove terms part which confuses Devise

    # This part is copied from Devise's regstration_controller#create
    build_resource
    @person = resource

    # Mark as organization user if signed up through market place which is only for orgs
    @person.is_organization = @current_community.only_organizations

    # Skip automatic email confirmation mail by devise, as that doesn't support custom sender address
    @person.skip_confirmation! 
  
    if @person.save!
      sign_in(resource_name, resource)
    end
  
    if @current_community.nil? || @current_community.email_confirmation
      # As automatic confirmation email was skipped, devise marks the person as confirmed, 
      # which isn't actually true, so fix it manually
      @person.update_attributes(:confirmation_sent_at => Time.now, :confirmed_at => nil) 

      # send the confirmation email manually
      @person.send_email_confirmation_to(@person.email, request.host_with_port, @current_community)
    end
  
    @person.set_default_preferences
    # Make person a member of the current community
    if @current_community
      membership = CommunityMembership.new(:person => @person, :community => @current_community, :consent => @current_community.consent)
      membership.status = "pending_email_confirmation" if @current_community.email_confirmation?
      # Deprecated
      membership.status = "pending_organization_membership" if @org_membership_required
      membership.invitation = invitation if invitation.present?
      # If the community doesn't have any members, make the first one an admin
      if @current_community.members.count == 0
        membership.admin = true
      end
      membership.save!
      session[:invitation_code] = nil
    end
  
    session[:person_id] = @person.id
    
    # If invite was used, reduce usages left
    invitation.use_once! if invitation.present?
    
    Delayed::Job.enqueue(CommunityJoinedJob.new(@person.id, @current_community.id)) if @current_community
    
    if !@current_community
      session[:consent] = APP_CONFIG.consent
      session[:unconfirmed_email] = params[:person][:email]
      session[:allowed_email] = "@#{params[:person][:email].split('@')[1]}" if community_email_restricted?
      redirect_to domain + new_tribe_path
    elsif @org_membership_required
      # Deprecated
      redirect_to :controller => "community_memberships", :action => "new"
    elsif @current_community.email_confirmation
      flash[:notice] = t("layouts.notifications.account_creation_succesful_you_still_need_to_confirm_your_email")
      redirect_to :controller => "sessions", :action => "confirmation_pending"
    else
      flash[:notice] = t("layouts.notifications.account_creation_successful", :person_name => view_context.link_to((@person.given_name_or_username).to_s, person_path(@person))).html_safe
      redirect_to(session[:return_to].present? ? domain + session[:return_to]: domain + root_path)
    end
  end
  
  def create_facebook_based
    username = Person.available_username_based_on(session["devise.facebook_data"]["username"])
    
    person_hash = {
      :username => username,
      :given_name => session["devise.facebook_data"]["given_name"],
      :family_name => session["devise.facebook_data"]["family_name"],
      :email => session["devise.facebook_data"]["email"],
      :facebook_id => session["devise.facebook_data"]["id"],
      :locale => I18n.locale,
      :test_group_number => 1 + rand(4),
      :confirmed_at => Time.now,  # We trust that Facebook has already confirmed these and save the user few clicks
      :password => Devise.friendly_token[0,20]
    }
    @person = Person.create!(person_hash)
    @person.set_default_preferences

    @person.store_picture_from_facebook
    

    session[:person_id] = @person.id    
    sign_in(resource_name, @person)
    flash[:notice] = t("layouts.notifications.login_successful", :person_name => view_context.link_to(@person.given_name_or_username, person_path(@person))).html_safe
    
    # We can create a membership for the user if there are no restrictions
    # - not an Invite only community
    # - has same terms of use
    # - if there's email limitation the user has suitable email in FB
    # But as this is bit complicated, for now   
    # we don't create the community membership yet, because we can use the already existing checks for invitations and email types.
    session[:fb_join] = "pending_analytics"
    redirect_to :controller => :community_memberships, :action => :new
  end
  
  def update

    # If setting new location, delete old one first
	  if params[:person] && params[:person][:location] && (params[:person][:location][:address].empty? || params[:person][:street_address].blank?)
      params[:person].delete("location")
      if @person.location
        @person.location.delete
      end
	  end
	  	  
	  #Check that people don't exploit changing email to be confirmed to join an email restricted community
	  if params["request_new_email_confirmation"] && @current_community && ! @current_community.email_allowed?(params[:person][:email])
	    flash[:error] = t("people.new.email_not_allowed")
	    redirect_to :back and return
    end
    
    # If person is changing email address, store the old confirmed address as additional email
    # One point of this is that same email cannot be used more than one in email restricted community
    # (This has to be remembered also when creating a possibility to modify additional emails)
    if params[:person][:email] && @person.confirmed_at
      Email.create(:person => @person, :address => @person.email, :confirmed_at => @person.confirmed_at) unless Email.find_by_address(@person.email)
    end

    payment_gateway = @current_community.payment_gateways && @current_community.payment_gateways.first

    # If updating payout details, check that they are valid
    if payment_gateway.type == "Mangopay" && params[:person] && (params[:person][:bank_account_owner_name] || params[:person][:bank_account_owner_address] || params[:person][:iban] || params[:person][:bic])
      
      # require all fields
      if params[:person][:bank_account_owner_name].blank? || params[:person][:bank_account_owner_address].blank? || params[:person][:iban].blank? || params[:person][:bic].blank?
        flash[:error] = t("layouts.notifications.you_must_fill_all_the_fields")
        redirect_to :back and return
      end
      
      # Try to register the details if payment gateway is present
      begin
        payment_gateway.register_payout_details(@person)
      rescue => e
        flash[:error] = e.message
        redirect_to :back and return
      end
    end

    # Checkout
    if (payment_gateway.type == "Checkout" && 
      params[:person] && 
      (params[:person][:company_id] || 
        params[:person][:organization_address] ||
        params[:person][:phone_number] ||
        params[:person][:organization_website]))

      # require all fields
      if (params[:person][:company_id].blank? ||
        params[:person][:organization_address].blank? ||
        params[:person][:phone_number].blank? ||
        params[:person][:organization_website].blank?)

        flash[:error] = t("layouts.notifications.you_must_fill_all_the_fields")
        redirect_to :back and return
      end

      # Try to register the details if payment gateway is present
      begin
        payment_gateway.register_payout_details(@person)
      rescue => e
        flash[:error] = e.message
        redirect_to :back and return
      end
    end

    begin
      if @person.update_attributes(params[:person])
        if params[:person][:password]
          #if password changed Devise needs a new sign in.
          sign_in @person, :bypass => true
        end
        flash[:notice] = t("layouts.notifications.person_updated_successfully")
        
        # Send new confirmation email, if was changing for that 
        if params["request_new_email_confirmation"]
            @person.send_confirmation_instructions(request.host_with_port, @current_community)
            flash[:notice] = t("layouts.notifications.email_confirmation_sent_to_new_address")
        end
      else
        flash[:error] = t("layouts.notifications.#{@person.errors.first}")
      end
    rescue RestClient::RequestFailed => e
      flash[:error] = t("layouts.notifications.update_error")
    end
    
    redirect_to :back
  end
  
  def destroy
    if @person && @current_user && @person == @current_user
      sign_out @current_user
      @current_user.destroy
      report_analytics_event(['user', "deleted", "by user"]);
      flash[:notice] = t("layouts.notifications.account_deleted")
    end
    
    redirect_to root
  end
  
  def check_username_availability
    respond_to do |format|
      format.json { render :json => Person.username_available?(params[:person][:username]) }
    end
  end
  
  #This checks also that email is allowed for this community
  def check_email_availability_and_validity
    
    # If asked from dashboard, only check availability
    return check_email_availability if @current_community.nil?
    
    # this can be asked from community_membership page or new user page 
    email = params[:person] && params[:person][:email] ? params[:person][:email] : params[:community_membership][:email]
        
    available = true
    
    #first check if the community allows this email
    if @current_community.allowed_emails.present?
      available = @current_community.email_allowed?(email)
    end
    
    if available
      # Then check if it's already in use
      check_email_availability
    else #respond false  
      respond_to do |format|
        format.json { render :json => available }
      end
    end
  end
  
  # this checks only that email is not already in use
  def check_email_availability
    email = params[:person] ? params[:person][:email] : params[:email] || params[:community_membership][:email]
    available = email_available_for_user?(@current_user, email)
    
    respond_to do |format|
      format.json { render :json => available }
    end
  end
  
  # this checks only that email is not already in use
  def check_email_availability_for_new_tribe
    email = params[:person] ? params[:person][:email] : params[:email]
    if email_available_for_user?(@current_user, email)
      existing_communities = Community.find_by_allowed_email(email)
      if existing_communities.size > 0 && Community.email_restricted?(params[:community_category])
        available = restricted_tribe_already_exists_error_message(existing_communities.first)      
      else
        available = true
      end
    else
      available = t("communities.signup_form.email_in_use_message")
    end
    
    respond_to do |format|
      format.json { render :json => available.to_json }
    end
  end
  
  def check_invitation_code
    respond_to do |format|
      format.json { render :json => Invitation.code_usable?(params[:invitation_code], @current_community) }
    end
  end
  
  def show_closed?
    params[:closed] && params[:closed].eql?("true")
  end

  def check_captcha
    if verify_recaptcha_unless_already_accepted
      render :json => "success" and return
    else
      render :json => "failed" and return
    end
  end
  
  # Showed when somebody tries to view a profile of
  # a person that is not a member of that community
  def not_member
  end

  def activate
    change_active_status("activated")
  end
  
  def deactivate
    change_active_status("deactivated")
  end

  def fetch_rdf_profile
    graph = RDF::Graph.load(params[:rdf_profile_url])

    fetched_data = {}
    name = query_graph(graph, "name")
    given_name = query_graph(graph, "givenName")
    fetched_data["given_name"] = given_name || name
    fetched_data["family_name"] = query_graph(graph, "familyName") 
    fetched_data["username"] = query_graph(graph, "nick") || given_name
    fetched_data["email"] = query_graph(graph, "mbox").to_s.sub("mailto:","")
    
    redirect_to new_person_path :person => fetched_data, :rdf_profile_url => params[:rdf_profile_url]
  end
  
  private
  
  def query_graph(graph, field)
    solutions = RDF::Query.execute(graph) do
      pattern [:person, RDF.type, FOAF.Person]
      pattern [:person, FOAF.send(field), :result]
    end
    
    if solutions.present?
      return solutions.first.result
    else
      return nil
    end
  end
  
  def verify_recaptcha_unless_already_accepted(options={})
    # Check if this captcha is already accepted, because ReCAPTCHA API will return false for further queries
    if session[:last_accepted_captha] == "#{params["recaptcha_challenge_field"]}#{params["recaptcha_response_field"]}"
      return true
    else
      accepted = verify_recaptcha(options)
      if accepted
        session[:last_accepted_captha] = "#{params["recaptcha_challenge_field"]}#{params["recaptcha_response_field"]}"
      end
      return accepted
    end
  end
  
  def change_active_status(status)
    @person = Person.find(params[:id])
    #@person.update_attribute(:active, 0)
    @person.update_attribute(:active, (status.eql?("activated") ? true : false))
    @person.listings.update_all(:open => false) if status.eql?("deactivated") 
    flash[:notice] = t("layouts.notifications.person_#{status}")
    respond_to do |format|
      format.html {
        redirect_to @person
      }
      format.js {
        render :layout => false 
      }
    end
  end
  
end
