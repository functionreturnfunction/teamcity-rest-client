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
    def misses
      []
    end
  end

  class ExcludeNoneFilter
    def retain? thing
      true
    end
    def misses
      []
    end
  end

  class IncludeFilter
    def initialize to_retain
      @misses = [to_retain].flatten
    end

    def retain? build_type
      @misses.delete(build_type.id) || @misses.delete(build_type.name) ? true : false
    end

    def misses
      @misses
    end
  end

  class ExcludeFilter
    def initialize to_exclude
      @misses = [to_exclude].flatten
    end

    def retain? build_type
      @misses.delete(build_type.id) || @misses.delete(build_type.name) ? false : true
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
      raise "Unsupported filter options #{filter}" unless filter.empty?
      build_types_for_project = teamcity.build_types.find_all { |bt| bt.project_id == id }
      filtered_build_types = build_types_for_project.find_all { |bt| including.retain?(bt) && excluding.retain?(bt) }
      raise "Failed to find a match for build type(s) #{including.misses}" if not including.misses.empty?
      raise "Failed to find a match for build type(s) #{excluding.misses}" if not excluding.misses.empty?
      filtered_build_types
    end

    def latest_builds filter = {}
      build_types(filter).collect(&:latest_build).reject(&:nil?)
    end

    def builds options = {}
      bt_ids = Set.new(build_types.collect(&:id))
      teamcity.builds(options).find_all { |b| bt_ids.include? b.build_type_id }
    end
  end

  class BuildType
    def initialize teamcity
      @teamcity = teamcity
      yield self if block_given?
    end

    attr_accessor :id, :name, :href, :project_name, :project_id, :web_url

    def builds options = {}
      teamcity.builds({:buildType => "id:#{id}"}.merge(options))
    end

    def latest_build
      builds(:count => 1)[0]
    end

    protected

    attr_reader :teamcity
  end

  class Build
    def initialize teamcity
      @teamcity = teamcity
      yield self if block_given?
    end

    def success?
      status == :SUCCESS
    end

    attr_accessor :id, :number, :status, :build_type_id, :start_date, :finish_date, :href, :web_url

    protected
    attr_reader :teamcity
  end

  class Authentication
    def initialize openuri_options
      @openuri_options = openuri_options
    end

    def get path, params = {}
      open(url(path, params), @openuri_options).read
    end

    def query_string_for params
      pairs = []
      params.each_pair { |k,v| pairs << "#{k}:#{v}" }
      pairs.join(",")
    end
  end

  class HttpBasicAuthentication < Authentication
    def initialize host, port, user, password, openuri_options = {}
      super({:http_basic_authentication => [user, password]}.merge(openuri_options))
      @host, @port, @user, @password = host, port, user, password
    end

    def url path, params = {}
      auth_path = path.start_with?("/httpAuth/") ? path : "/httpAuth#{path}"
      query_string = !params.empty? ? "?locator=#{query_string_for(params)}" : ""
      "http://#{@host}:#{@port}#{auth_path}#{query_string}"
    end

    def to_s
      "HttpBasicAuthentication #{@user}:#{@password}"
    end
  end

  class Open < Authentication
    def initialize host, port, options = {}
      super(options)
      @host, @port = host, port
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

  def et_or name, otherwise
    elem = elements[name]
    elem ? elem.text : otherwise
  end
end

class Teamcity
  attr_reader :host, :port, :authentication

  def initialize host, port, options = {}
    @host, @port = host, port
    if options[:user] && options[:password]
      @authentication = TeamcityRestClient::HttpBasicAuthentication.new(host, port, options.delete(:user), options.delete(:password), options)
    else
      @authentication = TeamcityRestClient::Open.new(host, port, options)
    end
  end

  def project spec
    field = spec =~ /project\d+/ ? :id : :name
    project = projects.find { |p| p.send(field) == spec }
    raise "Sorry, cannot find project with name or id '#{spec}'" unless project
    project
  end

  def projects
    doc(get(api_path('projects'))).elements.collect('//project') do |e|
      TeamcityRestClient::Project.new(self, e.av("name"), e.av("id"), url(e.av("href")))
    end
  end

  def build_types
    doc(get(api_path('buildTypes'))).elements.collect('//buildType') do |e|
      TeamcityRestClient::BuildType.new(self) do |b| # do |b| do
        b.id = e.av("id")
        b.name = e.av("name")
        b.href = url(e.av("href"))
        b.project_name = e.av('projectName')
        b.project_id = e.av('projectId')
        b.web_url = e.av('webUrl')
      end
    end
  end

  def builds options = {}
    doc(get(api_path('builds'), options).gsub(/&buildTypeId/,'&amp;buildTypeId')).elements.collect('//build') do |e|
      TeamcityRestClient::Build.new(self) do |b|
        b.id = e.av('id')
        b.number = e.av('number')
        b.status = e.av('status').to_sym
        b.build_type_id = e.av('buildTypeId')
        b.href = url(e.av('href'))
        b.web_url = e.av('webUrl')
      end
    end
  end

  def build id
    bld = doc(get(api_path('builds') + '/' + id).gsub(/&buildTypeId/,'&amp;buildTypeId')).elements.first
    TeamcityRestClient::Build.new(self) do |b|
      b.id = bld.av('id')
      b.number = bld.av('number')
      b.status = bld.av('status').to_sym
      b.build_type_id = bld.av('buildTypeId')
      b.href = url(bld.av('href'))
      b.web_url = bld.av('webUrl')

      b.start_date = bld.et_or('startDate', '')
      b.finish_date = bld.et_or('finishDate', '')
    end
  end

  def to_s
    "Teamcity @ #{url("/")}"
  end

  private
  def api_path item
    "/app/rest/#{item}"
  end

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
