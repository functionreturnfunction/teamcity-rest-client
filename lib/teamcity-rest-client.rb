require 'open-uri'
require 'rexml/document'
require 'set'

module TeamcityRestClient
  
  class Filter
  end
  
  class IncludeAllFilter
    def retain? thing
      true
    end
  end
  
  class ExcludeNoneFilter
    def retain? thing
      true
    end
  end
  
  class IncludeFilter
    def initialize to_retain
      @misses = [to_retain].flatten
      @hits = []
    end
    
    def retain? build_type
      puts "looking for match on #{build_type.id} or #{build_type.name} from includes #{@misses}"
      match = @misses.delete(build_type.id) || @misses.delete(build_type.name)
      if match
        @hits << match
        puts "hit with match #{match}"
        true
      else
        puts "miss"
        false
      end
    end
    
    def hits
      @hits      
    end
    
    def misses
      @misses
    end
  end
  
  class ExcludeFilter
    def initialize to_exclude
      @misses = [to_exclude].flatten
      @hits = []
    end
    
    def retain? build_type
      match = @misses.delete(build_type.id) || @misses.delete(build_type.name)
      if match
        @hits << match
        false
      else
        true
      end
    end
    
    def hits
      @hits      
    end
    
    def misses
      @misses
    end
  end
  
  class Project
    
    attr_reader :teamcity, :name, :id, :href
    
    def initialize teamcity, name, id, href
      @teamcity, @name, @id, @href = teamcity, name, id, href
    end
    
    def build_types filter = {}
      including = filter.has_key?(:include) ? IncludeFilter.new(filter.delete(:include)) : IncludeAllFilter.new
      excluding = filter.has_key?(:exclude) ? ExcludeFilter.new(filter.delete(:exclude)) : ExcludeNoneFilter.new
      build_types_for_project = teamcity.build_types.find_all { |bt| bt.project_id == id }
      build_types_for_project.find_all { |bt| including.retain?(bt) && excluding.retain?(bt) }
    end
    
    def latest_builds filter = {}
      build_types(filter).collect(&:latest_build)
    end
    
    def builds
      bt_ids = Set.new(build_types.collect(&:id))
      teamcity.builds.find_all { |b| bt_ids.include? b.build_type_id }
    end
  end
  
  BuildType = Struct.new(:teamcity, :id, :name, :href, :project_name, :project_id, :web_url) do
    #   httpAuth/app/rest/builds?buildType=id:bt107&count=1
    def latest_build
      teamcity.builds(:buildType => "id:#{id}", :count => 1)[0]
    end
  end
  
  Build = Struct.new(:teamcity, :id, :number, :status, :build_type_id, :start_date, :href, :web_url) do
    def success?
      status == :SUCCESS
    end
  end
  
  class Authentication
    def query_string_for params
      pairs = []
      params.each_pair { |k,v| pairs << "#{k}=#{v}" }
      pairs.join("&")
    end
  end

  class HttpBasicAuthentication < Authentication
    def initialize host, port, user, password
      @host, @port, @user, @password = host, port, user, password
    end

    def get path, params = {}
      open(url(path, params), :http_basic_authentication => [@user, @password]).read
    end

    def url path, params = {}
      auth_path = path.start_with?("/httpAuth/") ? path : "/httpAuth#{path}"
      query_string = !params.empty? ? "?#{query_string_for(params)}" : ""
      "http://#{@host}:#{@port}#{auth_path}#{query_string}"
    end  
    
    def to_s
      "HttpBasicAuthentication #{@user}:#{@password}"
    end
  end

  class Open < Authentication
    def initialize host, port
      @host, @port = host, port
    end

    def get path, params = {}
      open(url(path, params)).read
    end

    def url path, params = {}
      query_string = !params.empty? ? "?#{query_string_for(params)}" : ""
      "http://#{@host}:#{@port}#{path}#{query_string}"
    end
    
    def to_s
      "No Authentication"
    end
  end
end

class REXML::Element
  def av name
    attribute(name).value
  end
  
  def av_or name, otherwise
    att = attribute(name) 
    att ? att.value : otherwise
  end
end

class Teamcity
  
  attr_reader :host, :port, :authentication
  
  def initialize host, port, user = nil, password = nil
    @host, @port = host, port
    if user != nil && password != nil
      @authentication = TeamcityRestClient::HttpBasicAuthentication.new host, port, user, password
    else
      @authentication = TeamcityRestClient::Open.new host, port
    end
  end
  
  def project spec
    field = spec =~ /project\d+/ ? :id : :name  
    project = projects.find { |p| p.send(field) == spec }
    raise "Sorry, cannot find project with name or id '#{spec}'" unless project
    project
  end
  
  def projects
    doc(get('/app/rest/projects')).elements.collect('//project') do |e| 
      TeamcityRestClient::Project.new(self, e.av("name"), e.av("id"), url(e.av("href")))
    end
  end
  
  def build_types
    doc(get('/app/rest/buildTypes')).elements.collect('//buildType') do |e| 
      TeamcityRestClient::BuildType.new(self, e.av("id"), e.av("name"), url(e.av("href")), e.av('projectName'), e.av('projectId'), e.av('webUrl'))
    end
  end
  
  def builds options = {}
    doc(get('/app/rest/builds', options).gsub(/&buildTypeId/,'&amp;buildTypeId')).elements.collect('//build') do |e|
      TeamcityRestClient::Build.new(self, e.av('id'), e.av('number'), e.av('status').to_sym, e.av('buildTypeId'), e.av_or('startDate', ''), url(e.av('href')), e.av('webUrl'))
    end
  end
  
  def to_s
    "Teamcity @ #{url("/")}"
  end

  private
  def doc string
    REXML::Document.new string
  end

  def get path, params = {}
    result = @authentication.get(path, params)
    raise "Teamcity returned html, perhaps you need to use authentication??" if result =~ /.*<html.*<\/html>.*/im
    result
  end
  
  def url path
    @authentication.url(path)
  end
end
