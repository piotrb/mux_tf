module MuxTf
  class PlanFilenameGenerator
      def self.for_path(path = Dir.getwd)
        folder_name = File.basename(path)
        temp_dir = Dir.tmpdir
        hash = Digest::MD5.hexdigest(path)
        "#{temp_dir}/#{folder_name}-#{hash}.tfplan"
      end
  end
end
