require 'json'

class CbxLoco::Extension::Json < CbxLoco::Extension
  protected

  def bundle_translations
    @translations.each do |locale, trs|
      @translations[locale] = "\"#{locale}\": " + @translations[locale]
    end

    formatted = "{ #{@translations.values.join(", ")} }"
    @translations = nil

    formatted
  end

  def validate(file_path)
    begin
      JSON.parse(File.read(file_path))
    rescue Exception => e
      puts "\n\nFILE ERROR: \"#{file_path}\" is not JSON or is invalid:\n#{e}\n\n"
      exit(1)
    end
  end
end
