module Wedge
  class Component
    include Methods

    REJECTED_CLIENT_OPTS = %i(scope file_path methods_wrapped events klass on on_server_methods added_class_events loaded html)

    class << self
      # Override the default new behaviour
      def new(*args, &block)
        obj = allocate

        obj.wedge_opts.js   = args.delete(:js)
        obj.wedge_opts.init = args.delete(:init)

        # Merge other args into opts
        args.each { |a| a.each {|k, v| obj.wedge_opts[k] = v } } if args.any?

        obj.wedge_opts.events.scope = obj

        # Set all the on events
        obj.wedge_opts.on.each do |*a, &b|
          obj.wedge_opts.events.add(*a.first.first, &a.first.last)
        end
        wedge_opts.added_class_events = true

        if obj.wedge_opts.init
          if obj.wedge_opts.init.is_a? Array
            obj.send :initialize, *obj.wedge_opts.init, &block
          else
            obj.send :initialize, obj.wedge_opts.init, &block
          end
        else
          obj.send :initialize, &block
        end

        unless wedge_opts.methods_wrapped
          obj.wedge_opts.methods_wrapped = wedge_opts.methods_wrapped = true

          public_instance_methods(false).each do |meth|
            alias_method :"wedge_original_#{meth}", :"#{meth}"
            define_method "#{meth}" do |*d_args, &blk|
              if server? && !wedge_opts.method_called && wedge_opts.js
                wedge_opts.method_called = meth
                wedge_opts.method_args   = *d_args
              end

              o_name = "wedge_original_#{meth}"

              if client? || method(o_name).parameters.length > 0
                result = send(o_name, *d_args, &blk)
              else
                result = send(o_name, &blk)
              end

              # Append the initialize javscript
              if server? && opts.js
                result = result.to_html if result.is_a? DOM
                result << wedge_javascript if result.is_a? String
              end

              result
            end
          end
        end

        obj
      end

      # Used to setup the component with default options.
      #
      # @example
      #   class SomeComponent < Component
      #     setup do |config|
      #       config.name :some
      #     end
      #   end
      # @yield [Config]
      def wedge_setup(&block)
        block.call wedge_config
      end
      alias_method :setup, :wedge_setup

      # Set templates
      #
      # @example
      #   tmpl :some_name, dom.find('#some-div')
      # @return dom [DOM]
      def wedge_tmpl(name, dom = false, remove = true)
        if dom
          dom = remove ? dom.remove : dom
          wedge_opts.tmpl[name] = {
            dom:  dom,
            html: dom.to_html
          }
        elsif t = wedge_opts.tmpl[name]
          dom = DOM.new t[:html]
        else
          false
        end

        dom
      end
      alias_method :tmpl, :wedge_tmpl

      def wedge_dom
        @wedge_dom ||= DOM.new wedge_opts.html
      end
      alias_method :dom, :wedge_dom

      # Shortcut for Wedge.components
      #
      # @return [Hash, Wedge.components]
      def wedge_components
        Wedge.components ||= {}
      end
      alias_method :components, :wedge_components

      # Shortcut for the Config#opts
      #
      # @return [Openstruct, Config#opts]
      def wedge_opts
        wedge_config.opts
      end
      alias_method :opts, :wedge_opts

      def wedge_config
        @wedge_config ||= begin
          args = Wedge.config.opts_dup.merge(klass: self, object_events: {})

          unless RUBY_ENGINE == 'opal'
            args[:file_path] = caller.first.gsub(/(?<=\.rb):.*/, '')
            args[:path_name] = args[:file_path]
              .gsub(%r{(#{Dir.pwd}/|.*(?=wedge))}, '')
              .gsub(/\.rb$/, '')
          end

          c = Config.new(args)

          # If extending from a plugin it will automatically require it.
          ancestors.each do |klass|
            next if klass.to_s == name.to_s

            if klass.method_defined?(:wedge_opts) && klass.wedge_opts.name.to_s =~ /_plugin$/
              c.requires klass.wedge_opts.name
            end
          end

          c
        end
      end
      alias_method :config, :wedge_config

      def wedge_on(*args, &block)
        if args.first.to_s != 'server'
          wedge_opts.on << [args, block]
        else
          wedge_on_server(&block)
        end
      end
      alias_method :on, :wedge_on

      def method_missing(method, *args, &block)
        if wedge_opts.scope.respond_to?(method, true)
          wedge_opts.scope.send method, *args, &block
        else
          super
        end
      end

      def client_wedge_opts
        wedge_config.opts_dup.reject {|k, v| REJECTED_CLIENT_OPTS.include? k }
      end

      def wedge_on_server(&block)
        if server?
          yield
        else
          m = Module.new(&block)

          m.public_instance_methods(false).each do |meth|
            wedge_opts.on_server_methods << meth.to_s

            define_method "#{meth}" do |*args, &blk|
              path_name = wedge_opts.path_name
              # event_id = "comp-event-#{$faye.generate_id}"

              payload = client_wedge_opts.reject do |k, _|
                %w(html tmpl requires plugins object_events js_loaded).include? k
              end
              payload[:method_called] = meth
              payload[:method_args]   = args

              HTTP.post("/#{wedge_opts.assets_url}/#{path_name}.call",
                headers: {
                  'X-CSRF-TOKEN' => Element.find('meta[name=_csrf]').attr('content')
                },
                payload: payload) do |response|

                  # We set the new csrf token
                  xhr  = Native(response.xhr)
                  csrf = xhr.getResponseHeader('BIO-CSRF-TOKEN')
                  Element.find('meta[name=_csrf]').attr 'content', csrf
                  ###########################

                  res = JSON.from_object(`response`)

                  blk.call res[:body], res
              end

              true
            end
          end

          include m
        end
      end
    end

    # Duplicate of class condig [Config]
    # @return config [Config]
    def wedge_config
      @wedge_config ||= begin
        c = Config.new(self.class.wedge_config.opts_dup.merge(events: Events.new))
        c.opts.events.object_events = c.opts.object_events.dup
        c.opts.object_events = {}
        c
      end
    end
    alias_method :config, :wedge_config

    # Duplicated of config.opts [Config#opts]
    # @return opts [Config#opts]
    def wedge_opts
      wedge_config.opts
    end
    alias_method :opts, :wedge_opts

    # Grab a copy of the template
    # @return dom [DOM]
    def wedge_tmpl(name)
      self.class.wedge_tmpl name
    end
    alias_method :tmpl, :wedge_tmpl

    # Dom
    # @return wedge_dom [Dom]
    def wedge_dom
      @wedge_dom ||= begin
        if server?
          DOM.new self.class.wedge_dom.to_html
        else
          DOM.new(Element)
        end
      end
    end
    alias_method :dom, :wedge_dom

    # Special method that acts like the javascript equivalent
    # @example
    #   foo = {
    #     bar: function { |moo|
    #       moo.call 'something'
    #     }
    #   }.to_n
    def wedge_function(*args, &block)
      args.any? && raise(ArgumentError, '`function` does not accept arguments')
      block || raise(ArgumentError, 'block required')
      proc do |*a|
        a.map! {|x| Native(`x`)}
        @this = Native(`this`)
        %x{
         var bs = block.$$s,
            result;
          block.$$s = null;
          result = block.apply(self, a);
          block.$$s = bs;
          
          return result;
        }
      end
    end
    alias_method :function, :wedge_function

    def wedge_javascript
      return unless server?

      compiled_opts = Base64.encode64 client_wedge_opts.to_json
      name          = wedge_opts.file_path.gsub("#{Dir.pwd}/", '').gsub(/\.rb$/, '')

      javascript = <<-JS
        Wedge.javascript('#{name}', JSON.parse(Base64.decode64('#{compiled_opts}')))
      JS
      "<script>#{Opal.compile(javascript)}</script>"
    end
    alias_method :javscript, :wedge_javascript

    def client_wedge_opts
      wedge_config.opts_dup.reject {|k, v| REJECTED_CLIENT_OPTS.include? k }
    end
    alias_method :client_opts, :client_wedge_opts

    def wedge_trigger(*args)
      wedge_opts.events.trigger(*args)
    end
    alias_method :trigger, :wedge_trigger

    if RUBY_ENGINE == 'opal'
      def wedge(*args)
        Wedge[*args]
      end
    end

    def method_missing(method, *args, &block)
      if wedge_opts.scope.respond_to?(method, true)
        wedge_opts.scope.send method, *args, &block
      else
        super
      end
    end
  end
end
