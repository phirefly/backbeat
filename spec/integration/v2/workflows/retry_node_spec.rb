require 'spec_helper'
require "spec/helper/request_helper"

describe V2::Api, v2: true do
  include Rack::Test::Methods
  include RequestHelper

  def app
    FullRackApp
  end

  let(:v2_user) { FactoryGirl.create(:v2_user) }
  let(:v2_workflow) { FactoryGirl.create(:v2_workflow_with_node_running, user: v2_user) }
  let(:activity_node) { v2_workflow.nodes.where("parent_id IS NOT NULL").first }

  before do
    header 'CLIENT_ID', v2_user.id
    WebMock.stub_request(:post, "http://backbeat-client:9000/notifications")
  end

  context "client error" do
    it "retries with backoff and then succeeds" do
      WebMock.stub_request(:post, "http://backbeat-client:9000/activity")
        .with(:body => activity_hash(activity_node).to_json)
        .to_return(:status => 200, :body => "", :headers => {})

      expect(activity_node.reload.attributes).to include(
        "current_client_status" => "received",
        "current_server_status" => "sent_to_client"
      )
      expect(activity_node.node_detail.retries_remaining).to eq(4)

      response = put "/events/#{activity_node.id}/status/errored"

      V2::Workers::AsyncWorker.drain

      expect(activity_node.reload.attributes).to include(
        "current_client_status" => "received",
        "current_server_status" => "sent_to_client"
      )
      expect(activity_node.node_detail.retries_remaining).to eq(3)

      response = put "/events/#{activity_node.id}/status/completed"
      expect(activity_node.reload.attributes).to include(
        "current_client_status" => "complete",
        "current_server_status" => "processing_children"
      )

      V2::Workers::AsyncWorker.drain

      expect(activity_node.reload.attributes).to include(
        "current_client_status" => "complete",
        "current_server_status" => "complete"
      )
      expect(activity_node.parent.attributes).to include(
        "current_client_status" => "complete",
        "current_server_status" => "complete"
      )
    end

    it "retries full number of retries available and fails" do
      activity_node.reload.attributes.should include(
        "current_client_status" => "received",
        "current_server_status" => "sent_to_client"
      )
      activity_node.node_detail.update_attributes(retries_remaining: 2)
      expect(activity_node.node_detail.retries_remaining).to eq(2)

      WebMock.stub_request(:post, "http://backbeat-client:9000/activity")
        .with(:body => activity_hash(activity_node).to_json)
        .to_return(:status => 200, :body => "", :headers => {})

      2.times do |i|
        response = put "/events/#{activity_node.id}/status/errored"

        V2::Workers::AsyncWorker.drain

        expect(activity_node.reload.attributes).to include(
          "current_client_status" => "received",
          "current_server_status" => "sent_to_client"
        )
        expect(activity_node.node_detail.retries_remaining).to eq(1-i)
      end

      response = put "/events/#{activity_node.id}/status/errored"
      expect(activity_node.reload.attributes).to include(
        "current_client_status" => "errored",
        "current_server_status" => "errored"
      )
    end
  end
end
