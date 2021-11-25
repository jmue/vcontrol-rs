require 'open3'
require 'tempfile'
require 'base64'
require 'stringio'

require 'pycall/import'
include PyCall::Import
pyimport :io

VITOSOFT_DIR = 'src'
DATAPOINT_DEFINITION_VERSION_XML                  = "#{VITOSOFT_DIR}/ecnVersion.xml"
DATAPOINT_DEFINITIONS_XML                         = "#{VITOSOFT_DIR}/DPDefinitions.xml"
DATAPOINT_TYPES_XML                               = "#{VITOSOFT_DIR}/ecnDataPointType.xml"
EVENT_TYPES_XML                                   = "#{VITOSOFT_DIR}/ecnEventType.xml"
SYSTEM_DEVICE_IDENTIFIER_EVENT_TYPES_XML          = "#{VITOSOFT_DIR}/sysDeviceIdent.xml"
SYSTEM_DEVICE_IDENTIFIER_EXTENDED_EVENT_TYPES_XML = "#{VITOSOFT_DIR}/sysDeviceIdentExt.xml"
SYSTEM_EVENT_TYPES_XML                            = "#{VITOSOFT_DIR}/sysEventType.xml"
TEXT_RESOURCES_DIR                                = "#{VITOSOFT_DIR}"

desc 'download program for decoding .NET Remoting Binary Format data'
file 'nrbf.py' do |t|
  sh 'pip3', 'install', 'namedlist'
  sh 'curl', '-sSfL', 'https://github.com/gurnec/Undo_FFG/raw/HEAD/nrbf.py', '-o', t.name
  chmod '+x', t.name
end


task :import_nrbf => 'nrbf.py' do
  PyCall.sys.path.append Dir.pwd
  pyimport :nrbf
end

NRBF_CACHE = Pathname('nrbf-cache.json')

at_exit do
  next unless defined?(@dotnet_decode_cache)

  NRBF_CACHE.write JSON.pretty_generate(@dotnet_decode_cache)
end

def dotnet_decode(base64_string)
  @dotnet_decode_cache ||= NRBF_CACHE.exist? ? JSON.parse(NRBF_CACHE.read) : {}

  if @dotnet_decode_cache.key?(base64_string)
    return @dotnet_decode_cache[base64_string]
  end

  Rake::Task[:import_nrbf].invoke

  binary_string = Base64.strict_decode64(base64_string)
  bytes = io.BytesIO.new(binary_string)
  value = nrbf.read_stream(bytes)

  @dotnet_decode_cache[base64_string] = if value.respond_to?(:__class__)
    case class_name = value.__class__.__name__
    when 'System_Boolean', 'System_Int32', 'System_Double'
      value.m_value
    else
      raise "Uknown class: #{class_name}"
    end
  else
    value
  end
end

desc 'convert XML files to raw YAML files'
task :raw => [
  DATAPOINT_DEFINITION_VERSION_RAW,
  SYSTEM_EVENT_TYPES_RAW,
  SYSTEM_DEVICE_IDENTIFIER_EVENT_TYPES_RAW,
  SYSTEM_DEVICE_IDENTIFIER_EXTENDED_EVENT_TYPES_RAW,
  DATAPOINT_TYPES_RAW,
  DATAPOINT_DEFINITIONS_RAW,
  TRANSLATIONS_RAW,
]

file DATAPOINT_DEFINITION_VERSION_RAW => DATAPOINT_DEFINITION_VERSION_XML do |t|
  doc = Nokogiri::XML::Document.parse(File.open(t.source))
  doc.remove_namespaces!

  version = doc.at('/IEDataSet/Version/DataPointDefinitionVersion').text

  File.write t.name, version.to_yaml
end

def value_if_non_empty(node)
  v = node.text.strip
  v.empty? ? nil : v
end

# Only one company ID is used.
def assert_company_id(text)
  raise if Integer(text) != 24
end

def parse_bool(text)
  case text&.strip
  when nil, ''
    nil
  when 'true'
    true
  when 'false'
    false
  else
    raise
  end
end

def parse_value_list(text)
  text.split(';').map { |v| v.split('=', 2) }.map { |(k, v)| [k.to_i, clean_enum_text(k, v)] }.to_h
end

def parse_options_value(text)
  text.split(';').map { |v| v.split('=', 2) }.map { |(k, v)| [k, v] }.to_h
end

def parse_byte_array(text)
  text.empty? ? nil : text.delete_prefix('0x').each_char.each_slice(2).map { |c| Integer(c.join, 16) }
end

def parse_value(text)
  case text
  when /\A0x\h{2}+\Z/
    parse_byte_array(text)
  when /\A\-?(0|[1-9]\d*)\Z/
    Integer(text)
  when /\A\-?\d+[,.]\d+\Z/
    Float(text.sub(',', '.'))
  when /\A\d{2}.\d{2}.\d{4}\Z/
    text.split('.').reverse.join('-')
  when /\A\d{2}.\d{2}.\d{4} \d{2}:\d{2}:\d{2}\Z/
    date, time = text.split(' ')
    date = date.split('.').reverse.join('-')
    [date, time].join('T')
  when '', '--', 'TBD'
    nil
  else
    text
  end
end

def parse_fc(text)
  {
    ''                           => nil,
    'undefined'                  => nil,
    'Virtual_MarktManager_READ'  => 'virtual_market_manager_read',
    'Virtual_MarktManager_WRITE' => 'virtual_market_manager_write',
  }.fetch(text, text.underscore)
end

def event_types(path)
  reader = Nokogiri::XML::Reader(File.open(path))

  reader.map { |node|
    next unless node.name == 'EventType'

    fragment = Nokogiri::XML.fragment(node.inner_xml)
    next if fragment.children.empty?

    event_type = fragment.children.map { |n|
      value = case name = n.name.underscore
      when 'id'
        strip_address(n.text.strip)
      when 'active'
        parse_bool(n.text)
      when 'address'
        n.text.empty? ? nil : Integer(n.text, 16) rescue Float(n.text)
      when 'alz'
        name = 'default_value'
        parse_value(n.text.strip)
      when /^(block|byte|bit)_(length|position|factor)$/, 'mapping_type', 'rpc_handler', 'priority'
        Integer(n.text)
      when /^conversion_(factor|offset)$/
        Float(n.text)
      when /^((lower|upper)_border|stepping)$/
        Float(n.text)
      when 'access_mode'
        n.text.empty? ? nil : n.text.underscore
      when /^fc_(read|write)$/
        parse_fc(n.text)
      when 'option_list'
        n.text.split(';')
      when 'value_list'
        parse_value_list(n.text)
      when /^prefix_(read|write)$/
        n.text.empty? ? nil : n.text.delete_prefix('0x').each_char.each_slice(2).map { |c| Integer(c.join, 16) }
      else
        value_if_non_empty(n)
      end

      [name, value]
    }.to_h.compact

    [
      event_type.delete('id'),
      event_type,
    ]
  }.compact.to_h
end

file SYSTEM_EVENT_TYPES_RAW => SYSTEM_EVENT_TYPES_XML do |t|
  File.write t.name, event_types(t.source).to_yaml
end

file SYSTEM_DEVICE_IDENTIFIER_EVENT_TYPES_RAW => SYSTEM_DEVICE_IDENTIFIER_EVENT_TYPES_XML do |t|
  File.write t.name, event_types(t.source).to_yaml
end

file SYSTEM_DEVICE_IDENTIFIER_EXTENDED_EVENT_TYPES_RAW => SYSTEM_DEVICE_IDENTIFIER_EXTENDED_EVENT_TYPES_XML do |t|
  File.write t.name, event_types(t.source).to_yaml
end

file DATAPOINT_TYPES_RAW => DATAPOINT_TYPES_XML do |t|
  reader = Nokogiri::XML::Reader(File.open(t.source))
  datapoint_types = reader.map { |node|
    next unless node.name == 'DataPointType'

    fragment = Nokogiri::XML.fragment(node.inner_xml)
    next if fragment.children.empty?

    datapoint_type = fragment.children.map { |n|
      value = case name = n.name.underscore
      when 'controller_type', 'error_type', 'event_optimisation'
        Integer(n.text)
      when 'options'
        {
          'undefined' => nil,
        }.fetch(n.text, n.text)
      else
        value_if_non_empty(n)
      end

      [name, value]
    }.to_h.compact

    [
      datapoint_type.delete('id'),
      datapoint_type,
    ]
  }.compact.to_h

  File.write t.name, datapoint_types.sort_by_key.to_yaml
end

file DATAPOINT_DEFINITIONS_RAW => DATAPOINT_DEFINITIONS_XML do |t|
  datapoint_definitions = {}
  event_type_definitions = {}
  event_value_type_definitions = {}
  table_extensions = {}
  table_extension_values = {}

  reader = Nokogiri::XML::Reader(File.open(t.source))
  reader.each do |node|
    case node.name
    when 'ecnDatapointType'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      datapoint_type = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'id', 'event_type_id', 'status_event_type_id'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      datapoint_definitions[datapoint_type.delete('id')] = datapoint_type
    when 'ecnDataPointTypeEventTypeLink'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      link = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'data_point_type_id', 'event_type_id'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      data_point_type = datapoint_definitions.fetch(link.fetch('data_point_type_id'))
      data_point_type['event_types'] ||= []
      data_point_type['event_types'].push(link.fetch('event_type_id'))
      data_point_type['event_types'].sort!
    when 'ecnEventType'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      event_type = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'id', 'priority', 'config_set_id', 'config_set_parameter_id'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        when 'enum_type', 'filtercriterion', 'reportingcriterion'
          parse_bool(n.text)
        when 'address'
          strip_address(n.text.strip)
        when 'conversion'
          n.text.strip
        when 'default_value'
          parse_value(n.text.strip)
        when 'type'
          name = 'access_mode'
          case Integer(n.text.strip)
          when 1
            'read'
          when 2
            'write'
          when 3
            'read_write'
          else
            raise
          end
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      event_type_definitions[event_type.delete('id')] = event_type
    when 'ecnEventValueType'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      event_value_type = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'id', 'enum_address_value', 'status_type_id', 'value_precision', 'length'
          Integer(n.text.strip)
        when 'lower_border', 'upper_border', 'stepping'
          Float(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      event_value_type_definitions[event_value_type.delete('id')] = event_value_type
    when 'ecnEventTypeEventValueTypeLink'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      event_type_event_value_type_link = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'event_type_id', 'event_value_id'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      event_type = event_type_definitions.fetch(event_type_event_value_type_link.fetch('event_type_id'))
      event_type['value_types'] ||= []
      event_type['value_types'].push(event_type_event_value_type_link.fetch('event_value_id'))
    when 'ecnTableExtension'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      table_extension = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'id', 'internal_data_type'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        when 'pk_fields'
          n.text.split(';').map { |f| f.underscore }
        when 'internal_default_value'
          dotnet_decode(n.text)
        when 'options_value'
          parse_options_value(n.text)
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      table_extensions[table_extension.delete('id')] = table_extension
    when 'ecnTableExtensionValue'
      fragment = Nokogiri::XML.fragment(node.inner_xml)
      next if fragment.children.empty?

      table_extension_value = fragment.children.map do |n|
        value = case name = n.name.underscore
        when 'id', 'ref_id'
          Integer(n.text.strip)
        when 'company_id'
          assert_company_id(n.text.strip)
          nil
        when 'pk_value'
          n.text.split(';').map { |v| Integer(v) }
        when 'internal_value'
          dotnet_decode(n.text)
        else
          value_if_non_empty(n)
        end

        [name, value]
      end.to_h.compact

      table_extension_values[table_extension_value.delete('id')] = table_extension_value
    when 'ecnEventTypeGroup'
      next
    end
  end

  definitions = {
    'datapoints' => datapoint_definitions,
    'event_types' => event_type_definitions,
    'event_value_types' => event_value_type_definitions,
    'table_extensions' => table_extensions,
    'table_extension_values' => table_extension_values,
  }

  File.write t.name, definitions.sort_by_key.to_yaml
end

file TRANSLATIONS_RAW => TEXT_RESOURCES_DIR.to_s do |t|
  languages = {}
  translations = {}

  Pathname(t.source).glob('Textresource_*.xml').each do |text_resource|
    reader = Nokogiri::XML::Reader(text_resource.open)

    reader.each do |node|
      case node.name
      when 'Culture'
        id = node.attribute('Id')
        name = node.attribute('Name')

        languages[id] ||= name
      when 'TextResource'
        language_id = node.attribute('CultureId')
        label = node.attribute('Label')
        value = node.attribute('Value').strip.gsub('##ecnnewline##', "\n").gsub('##ecntab##', "\t").gsub('##ecnsemicolon##', ';').gsub('##nl##', "\n")

        if /~(?<index>\d+)$/ =~ label
          value = clean_enum_text(index, value)
        end

        translations[label] ||= {}
        translations[label][languages.fetch(language_id)] = value
      end
    end
  end

  File.write t.name, translations.sort_by_key.to_yaml
end
