require 'spec_helper'
require_relative 'event_se'

describe WorkflowServer::Models::Decision do
  before do
    @event_klass = WorkflowServer::Models::Decision
    @event_data = {name: :test_decision}
    @wf = FactoryGirl.create(:workflow)
    @d1 = FactoryGirl.create(:decision, workflow: @wf, name: "WF_Decision-1").reload
  end

  it_should_behave_like 'events'

  it "calls schedule next decision on create" do
    decision = WorkflowServer::Models::Decision.new(@event_data)
    decision.should_receive(:schedule_next_decision)
    decision.save!
  end

  context "#start" do
    it "calls make_decision and changes status to enqueued" do
      WorkflowServer::AsyncClient.should_receive(:make_decision).with(@d1)
      @d1.start
      @d1.status.should == :enqueued
    end
  end

  context "#completed" do
    it "adds a Flag to mark completion and checks with workflow manager to schedule the next decision" do
      @d2 = FactoryGirl.create(:decision, workflow: @wf, name: "WF_Decision-2")
      @d1.reload
      @d2.reload
      @d1.status.should == :enqueued
      @d2.status.should == :open
      @d1.completed
      @d1.children.count == 1
      child = @d1.children.first
      child.name.should == "#{@d1.name}_completed".to_sym
      @d2.reload
      @d2.status.should == :enqueued
    end
  end

  context "#child_completed" do
    it "calls refresh if child is Activity, Branch or Workflow" do
      [:activity, :workflow].each do |child|
        child = FactoryGirl.create(child, parent: @d1)
        @d1.should_receive(:refresh)
        @d1.child_completed(child)
      end
      [:flag, :signal].each do |child|
        child = FactoryGirl.create(child, parent: @d1)
        @d1.should_not_receive(:refresh)
        @d1.child_completed(child)
      end
    end
  end

  context "#change_status" do
    it "returns if the new status is the same as existing status" do
      expect {
        @d1.change_status(@d1.status)
      }.to_not raise_error
    end
    it "raises error if the new status field is invalid" do
      expect {
        @d1.change_status(:some_crap)
      }.to raise_error(WorkflowServer::InvalidEventStatus, "Invalid status some_crap")
    end
    context "deciding" do
      it "raises error unless status is enqueued" do
        @d1.update_status!(:open)
        expect {
          @d1.change_status(:deciding)
        }.to raise_error(WorkflowServer::InvalidEventStatus, "Decision WF_Decision-1 can't transition from open to deciding")
      end
      it "puts the decision in deciding state" do
        @d1.reload
        @d1.change_status(:deciding)
        @d1.status.should == :deciding
      end
    end
    context "#deciding_complete" do
      it "raises error unless status is enqueued / deciding" do
        @d1.update_status!(:open)
        expect {
          @d1.change_status(:deciding_complete)
        }.to raise_error(WorkflowServer::InvalidEventStatus, "Decision WF_Decision-1 can't transition from open to deciding_complete")
      end

      [:enqueued, :deciding].each do |base_state|
        it "puts the decision in completed state when no decisions" do
          @d1.update_status!(base_state)
          @d1.change_status(:deciding_complete)
          @d1.reload
          @d1.status.should == :complete
        end

        it "puts the decision in executing state and starts the first action" do
          @d1.update_status!(base_state)
          decisions = [
            {type: :flag, name: :wFlag},
            {type: :activity, name: :make_initial_payment, actor_type: "LineItem", actor_id: 100, retry: 100, retry_interval: 5},
            {type: :branch, name: :make_initial_payment_branch, actor_id: 100, retry: 100, retry_interval: 5},
            {type: :workflow, name: :some_name, workflow_type: :error_recovery_workflow, subject_type: "PaymentTerm", subject_id: 1000, decider: "ErrorDecider"},
            {type: :complete_workflow},
            {type: :timer, name: :wTimer, fires_at: Time.now + 1000.seconds}
          ]
          @d1.change_status(:deciding_complete, decisions: decisions)
          @d1.reload
          @d1.children.type(WorkflowServer::Models::Flag).first.status.should == :complete
          @d1.children.type(WorkflowServer::Models::Activity).first.status.should == :executing
          @d1.children.type([WorkflowServer::Models::Branch, WorkflowServer::Models::Workflow, WorkflowServer::Models::WorkflowCompleteFlag, WorkflowServer::Models::Timer]).each do |child|
            child.status.should == :open
          end
          @d1.status.should == :executing
        end
      end
    end
    context "#errored" do
      it "raises error unless status is enqueued / deciding" do
        @d1.update_status!(:open)
        expect {
          @d1.change_status(:errored)
        }.to raise_error(WorkflowServer::InvalidEventStatus, "Decision WF_Decision-1 can't transition from open to errored")
      end
      [:enqueued, :deciding].each do |base_state|
        it "puts the decision in error state and records the error - #{base_state}" do
          @d1.update_status!(base_state)
          @d1.change_status(:errored, error: {something: :bad_happened})
          @d1.reload
          @d1.status.should == :error
          @d1.status_history.last.should == {"from"=>base_state, "to"=>:error, "at"=>Time.now.to_datetime.to_s, "error"=>{"something"=>:bad_happened}}
        end
      end
    end
  end

  # context "#child_errored" do
  #   it "goes in error state" do
  #     @d1.status.should_not == :error
  #     @d1.child_errored(FactoryGirl.create(:flag), {something: :bad_happened})
  #     @d1.status.should == :error
  #     @d1.status_history.last.should == {from: :enqueued, to: :error, at: Time.now.to_datetime.to_s, error: {something: :bad_happened}}
  #   end
  # end
  # 
  # context "#child_timeout" do
  #   it "goes in timeout state" do
  #     @d1.status.should_not == :timeout
  #     @d1.child_timeout(FactoryGirl.create(:flag), {something: :timed_out})
  #     @d1.status.should == :timeout
  #     @d1.status_history.last.should == {from: :enqueued, to: :timeout, at: Time.now.to_datetime.to_s, error: {something: :timed_out}}
  #   end
  # end

  context "#start_next_action" do
    it "keeps starting the next actions till it hits a blocking action" do
      a1 = FactoryGirl.create(:activity, parent: @d1, workflow: @wf)
      a2 = FactoryGirl.create(:branch, mode: :non_blocking, parent: @d1, workflow: @wf)
      a3 = FactoryGirl.create(:workflow, parent: @d1, workflow: @wf)
      a4 = FactoryGirl.create(:flag, parent: @d1, workflow: @wf)
      @d1.reload
      @d1.__send__ :start_next_action

      a1.reload.status.should == :executing
      a2.reload.status.should == :open
      a3.reload.status.should == :open
      a4.reload.status.should == :open

      # simulate a1 is done
      a1.completed
      a1.reload.status.should == :complete
      a2.reload.status.should == :executing
      a3.reload.status.should == :executing
      a4.reload.status.should == :open
    end
  end

  context "#open_events" do
    it "yields on each open payment" do
      a1 = FactoryGirl.create(:activity, parent: @d1, workflow: @wf)
      a2 = FactoryGirl.create(:branch, mode: :non_blocking, parent: @d1, workflow: @wf)
      collected= []
      @d1.__send__(:open_events) do |event|
        collected << event
      end
      collected.should include(a1)
      collected.should include(a2)
    end
  end

  context "#any_incomplete_blocking_activities_branches_or_workflows?" do
    [:activity, :branch, :workflow].each do |event|
      it "returns true if any blocking #{event} is executing" do
        child = FactoryGirl.create(event, parent: @d1)
        @d1.__send__(:any_incomplete_blocking_activities_branches_or_workflows?).should == false
        child.update_status!(:executing)
        @d1.__send__(:any_incomplete_blocking_activities_branches_or_workflows?).should == true
        child.update_status!(:complete)
        @d1.__send__(:any_incomplete_blocking_activities_branches_or_workflows?).should == false
      end
    end
  end

  context "#all_activities_branches_and_workflows_completed?" do
    [:activity, :branch, :workflow].each do |event|
      it "returns true when all non-fire and forget #{event} are completed" do
        child = FactoryGirl.create(event, parent: @d1)
        @d1.__send__(:all_activities_branches_and_workflows_completed?).should == false
        child.update_attributes!(mode: :fire_and_forget)
        @d1.__send__(:all_activities_branches_and_workflows_completed?).should == true
        child.update_attributes!(mode: :blocking)
        @d1.__send__(:all_activities_branches_and_workflows_completed?).should == false
        child.update_attributes!(status: :complete)
        @d1.__send__(:all_activities_branches_and_workflows_completed?).should == true
      end
    end
  end
end