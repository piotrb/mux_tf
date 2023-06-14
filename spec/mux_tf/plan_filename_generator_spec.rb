# frozen_string_literal: true

RSpec.describe MuxTf::PlanFilenameGenerator do
  describe ".for_path" do
    let(:temp_dir) { Dir.tmpdir }

    context "when given a path" do
      let(:path) { "/path/to/folder" }
      let(:folder_name) { "folder" }

      it "returns a filename in the tmp directory" do
        expect(described_class.for_path(path)).to start_with(temp_dir)
      end

      it "returns a filename whose base name begins with the folder name" do
        expect(File.basename(described_class.for_path(path))).to start_with(folder_name)
      end

      it "returns a filename with the correct extension" do
        expect(described_class.for_path(path)).to end_with(".tfplan")
      end
    end

    context "when not given a path" do
      let(:path) { Dir.getwd }
      let(:folder_name) { File.basename(path) }

      it "returns a filename in the tmp directory" do
        expect(described_class.for_path(path)).to start_with(temp_dir)
      end

      it "returns a filename whose base name begins with the folder name" do
        expect(File.basename(described_class.for_path(path))).to start_with(folder_name)
      end

      it "returns a filename with the correct extension" do
        expect(described_class.for_path(path)).to end_with(".tfplan")
      end
    end
  end
end
