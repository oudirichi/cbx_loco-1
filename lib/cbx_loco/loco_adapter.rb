require 'rest-client'
require 'time'
require 'json'
require 'yaml'
require 'colorize'
require 'get_pomo'
require 'fileutils'

module CbxLoco
  def self.asset_tag(*args)
    args.join("-").gsub(/[^a-z,-]/i, "")
  end

  def self.flatten_hash(data_hash, parent = [])
    data_hash.flat_map do |key, value|
      case value
      when Hash then flatten_hash value, parent + [key]
      else (parent + [key]).join(".")
      end
    end
  end

  def self.file_path(*args)
    File.join(CbxLoco.configuration.root.to_s, *args).to_s
  end

  class LocoAdapter
    def self.get(api_path, params = {}, json = true)
      params = params.merge(key: CbxLoco.configuration.api_key, ts: Time.now.getutc)
      res = RestClient.get CbxLoco.configuration.api_url + api_path, params: params

      json ? JSON.parse(res.body) : res.body
    end

    def self.post(api_path, params = {})
      res = RestClient.post CbxLoco.configuration.api_url + api_path + "?key=#{CbxLoco.configuration.api_key}", params

      JSON.parse res.body
    end

    def self.valid_api_key?
      valid = CbxLoco.configuration.api_key.present?
      puts "MISSING I18N API KEY. ABORTING.".colorize(:red).bold unless valid
      valid
    end

    def self.extract
      return unless valid_api_key?

      puts "\n" + "Extract i18n assets".colorize(:green).bold

      print "Removing old files... "
      CbxLoco.configuration.i18n_files.each do |i18n_file|
        fmt = CbxLoco.configuration.file_formats[i18n_file[:format]]

        next unless fmt[:delete]

        path = fmt[:path]
        src_ext = fmt[:src_ext]
        i18n_file_path = CbxLoco.file_path path, [i18n_file[:name], src_ext].join(".")
        File.unlink i18n_file_path if File.file?(i18n_file_path)
      end
      puts "Done!".colorize(:green)

      run_event :before_extract

      @assets = {}
      CbxLoco.configuration.i18n_files.each do |i18n_file|
        fmt = CbxLoco.configuration.file_formats[i18n_file[:format]]
        path = fmt[:path]
        src_ext = fmt[:src_ext]

        case i18n_file[:format]
        when :gettext
          file_path = CbxLoco.file_path path, [i18n_file[:name], src_ext].join(".")
          translations = GetPomo::PoFile.parse File.read(file_path)
          msgids = translations.reject { |t| t.msgid.blank? }.map(&:msgid)
        when :yaml
          language = CbxLoco.configuration.languages.first
          file_path = CbxLoco.file_path path, [i18n_file[:name], language, src_ext].join(".")
          translations = YAML.load_file file_path
          msgids = CbxLoco.flatten_hash(translations[language])
        end

        msgids.each do |msgid|
          if msgid.is_a? Array
            # we have a plural (get text only)
            singular = msgid[0]
            plural = msgid[1]

            # add the singular
            @assets[singular] = { tags: [] } if @assets[singular].nil?
            @assets[singular][:tags] << CbxLoco.asset_tag(i18n_file[:id], i18n_file[:name])

            # add the plural
            @assets[plural] = { tags: [] } if @assets[plural].nil?
            @assets[plural][:singular_id] = singular
            @assets[plural][:tags] << CbxLoco.asset_tag(i18n_file[:id], i18n_file[:name])
          else
            @assets[msgid] = { tags: [] } if @assets[msgid].nil?
            @assets[msgid][:id] = msgid if i18n_file[:format] == :yaml
            @assets[msgid][:tags] << CbxLoco.asset_tag(i18n_file[:id], i18n_file[:name])
          end
        end
      end

      puts "\n" + "Upload i18n assets to Loco".colorize(:green).bold
      begin
        print "Grabbing the list of existing assets... "
        res = get "assets.json"
        existing_assets = {}
        res.each do |asset|
          existing_assets[asset["name"]] = { id: asset["id"], tags: asset["tags"] }
        end
        res = nil
        puts "Done!".colorize(:green)

        @assets.each do |asset_name, asset|
          existing_asset = existing_assets[asset_name]

          if existing_asset.nil?
            print_asset_name = asset_name.length > 50 ? asset_name[0..46] + "[...]" : asset_name
            print "Uploading asset: \"#{print_asset_name}\"... "

            asset_hash = { name: asset_name, type: "text" }

            if !asset[:singular_id].blank?
              singular_id = existing_assets[asset[:singular_id]][:id]
              res = post "assets/#{singular_id}/plurals.json", asset_hash
            else
              asset_hash[:id] = asset_name if asset[:id]
              res = post "assets.json", asset_hash
            end

            existing_asset = { id: res["id"], tags: res["tags"] }
            existing_assets[asset_name] = existing_asset
            puts "Done!".colorize(:green)
          end

          new_tags = asset[:tags] - existing_asset[:tags]
          new_tags.each do |tag|
            print_asset_id = existing_asset[:id].length > 30 ? existing_asset[:id][0..26] + "[...]" : existing_asset[:id]
            print "Uploading tag \"#{tag}\" for asset: \"#{print_asset_id}\"... "
            post "assets/#{URI.escape(existing_asset[:id])}/tags.json", name: tag
            puts "Done!".colorize(:green)
          end
        end

        puts "\n" + "All done!".colorize(:green).bold
      rescue => e
        res = JSON.parse e.response
        print_error "Upload to Loco failed: #{e.message}: #{res["error"]}"
      end
    end

    def self.import
      return unless valid_api_key?

      puts "\n" + "Import i18n assets from Loco".colorize(:green).bold
      begin
        CbxLoco.configuration.i18n_files.each do |i18n_file|
          CbxLoco.configuration.languages.each do |language|
            fmt = CbxLoco.configuration.file_formats[i18n_file[:format]]
            path = fmt[:path]
            dst_ext = fmt[:dst_ext]
            api_ext = fmt[:api_ext]
            tag = CbxLoco.asset_tag i18n_file[:id], i18n_file[:name]


            api_params = { filter: tag, order: :id }
            case i18n_file[:format]
            when :gettext
              api_params[:index] = "name"
              file_path = CbxLoco.file_path path, language, [i18n_file[:name], dst_ext].join(".")
            when :yaml
              api_params[:format] = "rails"
              file_path = CbxLoco.file_path path, [i18n_file[:name], language, dst_ext].join(".")
            end

            translations = get "export/locale/#{language}.#{api_ext}", api_params, false

            dirname = File.dirname(file_path)
            create_directory(dirname) unless File.directory?(dirname)

            print "Importing \"#{language}\" #{tag} assets... "
            f = File.new file_path, "w:UTF-8"
            f.write translations.force_encoding("UTF-8")
            f.close

            puts "Done!".colorize(:green)
          end
        end

        run_event :after_import

      rescue Errno::ENOENT => e
        print_error "Caught the exception: #{e}"
      rescue => e
        translations = {}
        GetPomo::PoFile.parse(e.response).each do |t|
          translations[t.msgid] = t.msgstr unless t.msgid.blank?
        end
        print_error "Download from Loco failed: #{translations["status"]}: #{translations["error"]}"
      end
    end

    private

    def self.create_directory(path)
      print "Creating \"#{path}\" folder... "

      FileUtils.mkdir_p(path)
      puts "Done!".colorize(:green)

      if File.directory?(path)
        print "Creating \".keep\" file... "
        file_path = CbxLoco.file_path path, ".keep"
        f = File.new file_path, "w:UTF-8"
        f.close
        puts "Done!".colorize(:green)
      end
    end

    def self.print_error(message)
      puts "\n\n" + message.colorize(:red).bold
    end


    def self.run_event(event_name)
      CbxLoco.configuration.tasks.with_indifferent_access

      callables = CbxLoco.configuration.tasks[event_name] || []
      callables.each { |callable| callable.call }
    end
  end
end
