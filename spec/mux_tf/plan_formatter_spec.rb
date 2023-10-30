# frozen_string_literal: true

RSpec.describe MuxTf::PlanFormatter do
  describe "#parse_lock_info" do
    let(:detail) do
      # rubocop:disable Layout/TrailingWhitespace
      <<~ERROR_MESSAGE
        ConditionalCheckFailedException: The conditional request failed
        Lock Info:
          ID:        821189ed-93ab-e878-ad43-f872349ecf77
          Path:      jane-terraform-eks-dev/admin/kluster-addons/terraform.tfstate
          Operation: OperationTypePlan
          Who:       piotr@Piotrs-Jane-MacBook-Pro-2.local
          Version:   1.5.4
          Created:   2023-09-26 23:38:59.539088 +0000 UTC
          Info:      

        Terraform acquires a state lock to protect the state from being written
        by multiple users at the same time. Please resolve the issue above and try
        again. For most commands, you can disable locking with the "-lock=false"
        flag, but this is not recommended.
      ERROR_MESSAGE
      # rubocop:enable Layout/TrailingWhitespace
    end

    let(:expected) do
      {
        "ID" => "821189ed-93ab-e878-ad43-f872349ecf77",
        "Path" => "jane-terraform-eks-dev/admin/kluster-addons/terraform.tfstate",
        "Operation" => "OperationTypePlan",
        "Who" => "piotr@Piotrs-Jane-MacBook-Pro-2.local",
        "Version" => "1.5.4",
        "Created" => "2023-09-26 23:38:59.539088 +0000 UTC"
      }
    end

    it("returns a hash with lock info") do
      info = described_class.parse_lock_info(detail)
      expect(info).to eq(expected)
    end
  end
end
