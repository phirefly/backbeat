module Api
  class Health
    def initialize(app)
      @app = app
    end

    ENDPOINT = '/health'.freeze
    def call(env)
      if env['PATH_INFO'] == ENDPOINT
        return [ 200, {"Content-Type" => "text/plain"}, [WorkflowServer::Models::Workflow.last.try(:created_at).to_s] ]
      end
      status, headers, body = @app.call(env)
      [status, headers, body]
    end
  end
end
