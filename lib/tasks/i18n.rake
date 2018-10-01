namespace :i18n do
  require 'cbx_loco'

  def load_env
    path = Rails.root.join("config", "initializers", "cbx_loco.rb").to_s
    if File.exist?(path) && File.file?(path)
      begin
        load path
      rescue => error
      end
    else
      puts "CANNOT LOAD #{path}".colorize(:red).bold
      exit(1)
    end
  end

  desc "Extract i18n assets, and upload them to Loco"
  task :extract do
    command = { extract: true }
    load_env

    CbxLoco.run command
  end

  desc "Import compiled i18n assets from Loco"
  task :import do
    command = { import: true }

    load_env
    CbxLoco.run command
  end
end
