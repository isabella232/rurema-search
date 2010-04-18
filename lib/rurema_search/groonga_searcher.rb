# -*- coding: utf-8 -*-
# Copyright (c) 2010 Kouhei Sutou <kou@clear-code.com>
#
# License: LGPLv3+

require 'erb'

module RuremaSearch
  class GroongaSearcher
    include Rack::Utils

    def initialize(database, base_dir)
      @database = database
      @base_dir = base_dir
      setup_view
    end

    def call(env)
      request = Rack::Request.new(env)
      response = Rack::Response.new
      response["Content-Type"] = "text/html; charset=UTF-8"

      if request.post?
        query = request['query'] || ''
        if query.empty?
          request.path_info = "/"
        else
          request.path_info = "/query:#{escape(query)}/"
        end
        response.redirect(request.url.split(/\?/, 2)[0])
      else
        context = SearchContext.new(@database, request, response)
        context.extend(@view)
        context.process
      end
      response.to_a
    end

    private
    def setup_view
      @view = Module.new
      ["layout", "search_result"].each do |template_name|
        template = create_template(template_name)
        @view.send(:define_method, template_name) do
          template.result(binding)
        end
      end
    end

    def create_template(name)
      template_file = File.join(@base_dir, "views", "#{name}.html.erb")
      erb = ERB.new(File.read(template_file), 0, "%<>")
      erb.filename = template_file
      erb
    end

    class SearchContext
      include ERB::Util

      def initialize(database, request, response)
        @database = database
        @request = request
        @response = response
        @url_mappers = {}
      end

      def process
        start = Time.now.to_i
        _, *parameters = @request.path_info.split(/\//)
        @query = ''
        @version = nil
        parameters.each do |parameter|
          key, value = parameter.split(/:/, 2)
          case key
          when "query"
            @query = URI.unescape(value)
          when "version"
            @version = value
          end
        end
        entries = @database.entries
        if @query.empty?
          @n_entries = entries.size
          @drilldown_result = drilldown_items(entries)
          result = entries.select.select("_score = rand()", :syntax => :script)
        else
          result = @database.entries.select do |record|
            (record["name"] =~ @query) | (record["document"] =~ @query)
          end
          @n_entries = result.size
          @drilldown_result = drilldown_items(result)
        end
          @entries = result.sort([["_score", :descending]], :limit => 10)
        @elapsed_time = Time.now.to_f - start.to_f
        @response.write(layout)
      end

      private
      def drilldown_items(entries)
        result = []
        result << [:version, drilldown_item(entries, "version", "_key")]
        result << [:class, drilldown_item(entries, "class", "name")]
        result
      end

      def drilldown_item(entries, drilldown_column, label_column)
        result = entries.group(drilldown_column)
        result = result.sort([["_nsubrecs", :descending]], :limit => 10)
        result.collect do |record|
          {
            :label => record[label_column],
            :n_records => record.n_sub_records
          }
        end
      end

      def title
        "Rubyリファレンスマニュアル"
      end

      def h1
        title
      end

      def link_entry(entry)
        a(h("#{entry.name}: (#{entry.version.key})"),
          entry_href(entry))
      end

      def entry_href(entry)
        mapper = url_mapper(entry.version.key)
        case entry.type.key
        when "class"
          mapper.class_url(entry.name)
        when "constant", "variable", "instance method", "singleton method"
          mapper.method_url(entry.name)
        else
          "/#{entry.type.key}"
        end
      end

      def a(label, href, attributes={})
        tag("a", attributes.merge(:href => href), label)
      end

      def tag(name, attributes={}, content=nil)
        _tag = "<#{name}"
        attributes.each do |key, value|
          _tag << " #{h(key)}=\"#{h(value)}\""
        end
        if content
          _tag << ">#{content}</#{name}>"
        else
          if no_content_tag_name?(name)
            _tag << " />"
          else
            _tag << "></#{name}>"
          end
        end
        _tag
      end

      NO_CONTENT_TAG_NAMES = ["meta", "img"]
      def no_content_tag_name?(name)
        NO_CONTENT_TAG_NAMES.include?(name)
      end

      def url_mapper(version)
        @url_mappers[version] ||= create_url_mapper(version)
      end

      def create_url_mapper(version)
        RuremaSearch::URLMapper.new(:base_url => "/",
                                    :version => version)
      end
    end
  end
end
