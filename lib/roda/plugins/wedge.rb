class Roda
  module RodaPlugins
    module Wedge
      def self.configure(app, opts = {})
        if app.opts[:wedge]
          app.opts[:wedge].merge!(opts)
        else
          app.opts[:wedge] = opts.dup
        end

        opts = app.opts[:wedge]

        opts.each do |k, v|
          case k.to_s
          when 'plugins'
            v.each { |p| ::Wedge.config.plugin p }
          when 'scope'
            begin
              ::Wedge.config.scope v.new
            rescue
              ::Wedge.config.scope v.new('')
            end
          else
            ::Wedge.config.send(k, v)
          end
        end
      end

      module InstanceMethods
        def wedge(*args)
          args << { scope: self }
          ::Wedge[*args]
        end
      end

      module RequestClassMethods
        def wedge_route_regex
          assets_url = ::Wedge.assets_url.gsub(%r{^(http://[^\/]*\/|\/)}, '')
          %r{#{assets_url}/(.*)\.(.*)$}
        end
      end

      module RequestMethods
        def wedge_assets
          on self.class.wedge_route_regex do |component, ext|
            case ext
            when 'map'
              ::Wedge.source_map component
            when 'rb'
              if component =~ /^wedge/
                path = ::Wedge.opts.file_path.gsub(/\/wedge.rb$/, '')
                File.read("#{path}/#{component}.rb")
              else
                File.read("#{ROOT_PATH}/#{component}.rb")
              end
            when 'call'
              body = scope.request.body.read
              data = scope.request.params

              begin
                data.merge!(body ? JSON.parse(body) : {})
              rescue
                # can't be parsed by json
              end

              data          = data.indifferent
              name          = data.delete(:name)
              method_called = data.delete(:method_called)
              method_args   = data.delete(:method_args)

              res = scope.wedge(name, data).send(method_called, *method_args) || ''

              scope.response.headers["BIO-CSRF-TOKEN"] = scope.csrf_token if scope.methods.include? :csrf_token

              if res.is_a? Hash
                scope.response.headers["Content-Type"] = 'application/json; charset=UTF-8'
                res = res.to_json
              else
                res = res.to_s
              end

              res
            else
              "#{::Wedge.javascript(component)}\n//# sourceMappingURL=/assets/wedge/#{component}.map"
            end
          end
        end
      end
    end

    register_plugin(:wedge, Wedge)
  end
end
