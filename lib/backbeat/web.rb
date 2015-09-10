# Copyright (c) 2015, Groupon, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# Neither the name of GROUPON nor the names of its contributors may be
# used to endorse or promote products derived from this software without
# specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'grape'
require 'backbeat/web/middleware/log'
require 'backbeat/web/middleware/health'
require 'backbeat/web/middleware/heartbeat'
require 'backbeat/web/middleware/sidekiq_stats'
require 'backbeat/web/middleware/authenticate'
require 'backbeat/web/middleware/camel_case'
require 'backbeat/web/events_api'
require 'backbeat/web/workflows_api'
require 'backbeat/web/debug_api'

module Backbeat
  module Web
    class API < Grape::API
      format :json

      before do
        @params = Client::HashKeyTransformations.underscore_keys(params)
      end

      rescue_from :all do |e|
        Logger.error({error_type: e.class, error: e.message, backtrace: e.backtrace})
        Rack::Response.new({error: e.message }.to_json, 500, { "Content-type" => "application/json" }).finish
      end

      rescue_from ActiveRecord::RecordNotFound do |e|
        Logger.info(e)
        Rack::Response.new({error: e.message }.to_json, 404, { "Content-type" => "application/json" }).finish
      end

      RESCUED_ERRORS = [
        WorkflowComplete,
        Grape::Exceptions::Validation,
        Grape::Exceptions::ValidationErrors
      ]

      rescue_from *RESCUED_ERRORS do |e|
        Logger.info(e)
        Rack::Response.new({ error: e.message }.to_json, 400, { "Content-type" => "application/json" }).finish
      end

      rescue_from InvalidServerStatusChange do |e|
        Logger.info(e)
        Rack::Response.new({ error: e.message }.to_json, 500, { "Content-type" => "application/json" }).finish
      end

      rescue_from InvalidClientStatusChange do |e|
        Logger.info(e)
        Rack::Response.new(e.data.merge(error: e.message).to_json, 409, { "Content-type" => "application/json" }).finish
      end

      mount WorkflowsApi
      mount EventsApi
      mount WorkflowEventsApi
      mount DebugApi
    end

    App = Rack::Builder.new do
      use ActiveRecord::ConnectionAdapters::ConnectionManagement
      use Middleware::Log
      use Middleware::Heartbeat
      use Middleware::Health
      use Middleware::SidekiqStats
      use Middleware::CamelCase
      use Middleware::Authenticate

      run API
    end
  end
end
