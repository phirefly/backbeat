require 'spec_helper'

describe Api::Workflow do
  include Rack::Test::Methods

  def app
    FullRackApp
  end

  before do
    header 'CLIENT_ID', RSPEC_CONSTANT_USER_CLIENT_ID
    WorkflowServer::Client.stub(:make_decision)
    @user = FactoryGirl.create(:user, id: UUIDTools::UUID.random_create.to_s)
    @wf = FactoryGirl.create(:workflow)
    @d1 = FactoryGirl.create(:decision, workflow: @wf)
  end

  def uri(template, event)
    event_id = event.id
    workflow_id = event.workflow.id
    message = ERB.new(template)
    message.result(binding)
  end

  ["/workflows/<%=workflow_id%>/events/<%=event_id%>", "/events/<%=event_id%>"].each do |template|
    context "GET #{template}" do
      it "returns an event object with valid params" do
        decision = FactoryGirl.create(:decision)
        get uri(template, decision)
        last_response.status.should == 200
        json_response = JSON.parse(last_response.body)
        json_response.should == {"createdAt"=>Time.now.to_datetime.to_s, "decider" => "PaymentDecider", "name"=>"WFDecision", "parentId"=>nil, "status"=>"enqueued", "updatedAt"=>Time.now.to_datetime.to_s, "workflowId"=>decision.workflow.id, "id"=>decision.id, "type"=>"decision", "pastFlags"=>[], "subjectKlass"=>"PaymentTerm", "subjectId"=>100}
        json_response['id'].should == decision.id.to_s
      end

      it "returns the past flags" do
        name = 'decision'
        flag = FactoryGirl.create(:flag, name: "#{name}_completed")
        wf = flag.workflow
        decision = FactoryGirl.create(:decision, name: name, workflow: wf)
        get uri(template, decision)
        last_response.status.should == 200
        json_response = JSON.parse(last_response.body)
        json_response['pastFlags'].should == ["#{name}_completed"]
      end

      it "returns a 404 if the event is not found" do
        wf = FactoryGirl.create(:workflow)
        event = mock('mock', id: 1000, workflow: wf)
        get uri(template, event)
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Event with id(1000) not found"}
      end

      it "returns a 404 if a user tries to access a workflow that doesn't belong to them" do
        decision = FactoryGirl.create(:decision)
        user = FactoryGirl.create(:user, id: UUIDTools::UUID.random_create.to_s)
        header 'CLIENT_ID', user.id
        get uri(template, decision)
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == (template.match(/^\/workflows/) ? {"error" => "Workflow with id(#{decision.workflow.id}) not found"} : {"error" => "Event with id(#{decision.id}) not found"})
      end
    end

    context "GET #{template}/tree" do
      it "returns a tree of the event with valid params" do
        get "#{uri(template, @d1)}/tree"
        last_response.status.should == 200
        json_response = JSON.parse(last_response.body)
        json_response.should == {"id"=>@d1.id, "type"=>"decision", "name"=>"WFDecision", "status"=>"enqueued"}
      end

      it "returns a 404 if the event is not found" do
        event = mock('mock', id: 1000, workflow: @d1.workflow)
        get "#{uri(template, event)}/tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Event with id(1000) not found"}
      end

      it "returns a 404 if a user tries to access a workflow that doesn't belong to them" do
        header 'CLIENT_ID', @user.id
        get "#{uri(template, @d1)}/tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == (template.match(/^\/workflows/) ? {"error" => "Workflow with id(#{@d1.workflow.id}) not found"} : {"error" => "Event with id(#{@d1.id}) not found"})
      end
    end

    context "GET #{template}/print" do
      it "returns a tree of the event with valid params" do
        get "#{uri(template, @d1)}/tree/print"
        last_response.status.should == 200
        json_response = JSON.parse(last_response.body)
        json_response.should == {"print"=>"\e[36m*--\e[0mDecision:WFDecision is enqueued.\n"}
      end

      it "returns a 404 if the event is not found" do
        event = mock('mock', id: 1000, workflow: @d1.workflow)
        get "#{uri(template, event)}/tree/print"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Event with id(1000) not found"}
      end

      it "returns a 404 if a user tries to access a workflow that doesn't belong to them" do
        header 'CLIENT_ID', @user.id
        get "#{uri(template, @d1)}/tree/print"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == (template.match(/^\/workflows/) ? {"error" => "Workflow with id(#{@d1.workflow.id}) not found"} : {"error" => "Event with id(#{@d1.id}) not found"})
      end
    end

    context "GET #{template}/big_tree" do
      it "returns a big_tree of the event with valid params" do
        get "#{uri(template, @d1)}/big_tree"
        last_response.status.should == 200
        json_response = JSON.parse(last_response.body)
        json_response.should == {"createdAt"=>Time.now.to_datetime.to_s, "name"=>"WFDecision", "parentId"=>nil, "status"=>"enqueued", "updatedAt"=>Time.now.to_datetime.to_s, "workflowId"=>@wf.id, "id"=>@d1.id, "type"=>"decision", "pastFlags"=>[], "decider"=>"PaymentDecider", "subjectKlass"=>"PaymentTerm", "subjectId"=>100}
      end

      it "returns a 404 if the event is not found" do
        event = mock('mock', id: 1000, workflow: @d1.workflow)
        get "#{uri(template, event)}/big_tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Event with id(1000) not found"}
      end

      it "returns a 404 if a user tries to access a workflow that doesn't belong to them" do
        header 'CLIENT_ID', @user.id
        get "#{uri(template, @d1)}/big_tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == (template.match(/^\/workflows/) ? {"error" => "Workflow with id(#{@d1.workflow.id}) not found"} : {"error" => "Event with id(#{@d1.id}) not found"})
      end
    end
  end

  # specific to the workflow endpoint
  ["/workflows/<%=workflow_id%>/events/<%=event_id%>"].each do |template|
    context "GET #{template}/tree" do
      it "returns a 404 if the workflow is not found" do
        @d1.stub_chain(:workflow, :id => 1000)
        get "#{uri(template, @d1)}/tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Workflow with id(1000) not found"}
      end
    end
    context "GET #{template}/print" do
      it "returns a 404 if the workflow is not found" do
        @d1.stub_chain(:workflow, :id => 1000)
        get "#{uri(template, @d1)}/tree/print"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Workflow with id(1000) not found"}
      end
    end
    context "GET #{template}/big_tree" do
      it "returns a 404 if the workflow is not found" do
        @d1.stub_chain(:workflow, :id => 1000)
        get "#{uri(template, @d1)}/big_tree"
        last_response.status.should == 404
        json_response = JSON.parse(last_response.body)
        json_response.should == {"error" => "Workflow with id(1000) not found"}
      end
    end

  end
end
