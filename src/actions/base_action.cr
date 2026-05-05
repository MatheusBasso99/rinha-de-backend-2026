require "http/server"

module RinhaDeBackend
  abstract class BaseAction
    abstract def http_method : String
    abstract def path : String
    abstract def call(context : HTTP::Server::Context) : Nil

    macro route(verb, route_path)
      def http_method : String
        {{verb}}
      end

      def path : String
        {{route_path}}
      end
    end

    protected def respond_json(context : HTTP::Server::Context, status_code : Int32, body : String) : Nil
      context.response.status_code = status_code
      context.response.headers["Content-Type"] = "application/json"
      context.response.print(body)
    end

    protected def respond_empty(context : HTTP::Server::Context, status_code : Int32) : Nil
      context.response.status_code = status_code
    end
  end
end
