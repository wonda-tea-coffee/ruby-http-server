require 'socket'

class FileServingApp
  # リクエストで受け突ったパスを元にファイルシステムからファイルを読み取る
  # 例: "/text.txt"
  def call(env)

    # セキュリティ的には非常によくないが、デモ用には十分
    path = Dir.getwd + env['PATH_INFO']
    if File.exist?(path)
      body = File.read(path)
      [200, { 'Content-Type' => 'text/html' }, [body]]
    else
      [404, { 'Content-Type' => 'text/html' }, ['']]
    end
  end
end

class HttpResponder
  STATUS_MESSAGES = {
    # ...
    200 => 'OK',
    # ...
    404 => 'Not Found',
    # ..
  }.freeze

  # status: int
  # headers: ハッシュ
  # body: 文字列の配列
  def self.call(conn, status, headers, body)
    # ステータス行
    status_text = STATUS_MESSAGES[status]
    conn.send("HTTP/1.1 #{status} #{status_text}\r\n", 0)

    # ヘッダー
    # 送信前に本文の長さを知る必要がある
    # それによってリモートクライアントが読み取りをいつ終えるかがわかる
    content_length = body.sum(&:bytesize)
    conn.send("Content-Length: #{content_length}\r\n", 0)
    headers.each_pair do |name, value|
      conn.send("#{name}: #{value}\r\n", 0)
    end

    # コネクションを開きっぱなしにしたくないことを伝える
    conn.send("Connection: close\r\n", 0)

    # ヘッダーと本文の間を空行で区切る
    conn.send("\r\n", 0)

    # 本文
    body.each do |chunk|
      conn.send(chunk, 0)
    end
  end
end

class RequestParser
  MAX_URI_LENGTH = 2083 # HTTP標準に準拠
  MAX_HEADER_LENGTH = (112 * 1024) # WebrickやPumaなどのサーバーではこう定義する

  class << self
    def call(conn)
      method, full_path, path, query = read_request_line(conn)

      headers = read_headers(conn)

      body = read_body(conn: conn, method: method, headers: headers)

      # リモート接続に関する情報を読み取る
      peeraddr = conn.peeraddr
      remote_host = peeraddr[2]
      remote_address = peeraddr[3]

      # 利用するポート
      port = conn.addr[1]
      {
        'REQUEST_METHOD' => method,
        'PATH_INFO' => path,
        'QUERY_STRING' => query,
        # rack.inputはIOストリームである必要がある
        'rack.input' => body ? StringIO.new(body) : nil,
        'REMOTE_ADDR' => remote_address,
        'REMOTE_HOST' => remote_host,
        'REQUEST_URI' => make_request_uri(
          full_path: full_path,
          port: port,
          remote_host: remote_host
        )
      }.merge(rack_headers(headers))
    end

    def rack_headers(headers)
      # Rackは、全ヘッダーがHTTP_がプレフィックスされ
      # かつ大文字であることを期待する
      headers.transform_keys do |key|
        "HTTP_#{key.upcase}"
      end
    end

    def make_request_uri(full_path:, port:, remote_host:)
      request_uri = URI::parse(full_path)
      request_uri.scheme = 'http'
      request_uri.host = remote_host
      request_uri.port = port
      request_uri.to_s
    end

    def read_request_line(conn)
      # 例: "POST /some-path?query HTTP/1.1"

      # 改行に達するまで読み取る、最大長はMAX_URI_LENGTHを指定
      request_line = conn.gets("\n", MAX_URI_LENGTH)
      method, full_path, _http_version = request_line.strip.split(' ', 3)
      path, query = full_path.split('?', 2)
      [method, full_path, path, query]
    end

    def read_headers(conn)
      headers = {}
      loop do
        line = conn.gets("\n", MAX_HEADER_LENGTH)&.strip

        break if line.nil? | line.strip.empty?

        # ヘッダー名と値はコロンとスペースで区切られる
        key, value = line.split(/:\s/, 2)

        headers[key] = value
      end

      headers
    end

    def read_body(conn:, method:, headers:)
      return nil unless ['POST', 'PUT'].include?(method)

      remaining_size = headers['content-length'].to_i

      conn.read(remaining_size)
    end
  end
end

class SingleThreadServer
  PORT = ENV.fetch('PORT', 3000)
  HOST = ENV.fetch('HOST', '127.0.0.1').freeze
  # バッファに保存する受信コネクション数
  SOCKET_READ_BACKLOG = ENV.fetch('TCP_BACKLOG', 12).to_i

  attr_accessor :app

  # app: Rackアプリ
  def initialize(app)
    self.app = app
  end

  def start
    socket = listen_on_socket

    loop do # 新しいコネクションを継続的にリッスンする
      conn, _addr_info = socket.accept
      request = RequestParser.call(conn)
      status, headers, body = app.call(request)
      HttpResponder.call(conn, status, headers, body)
    rescue => e
      puts e.message
    ensure # コネクションを常にクローズする
      conn&.close
    end
  end

  private

  def listen_on_socket
    socket = TCPServer.new(HOST, PORT)
    socket.listen(SOCKET_READ_BACKLOG)
    socket
  end
end

SingleThreadServer.new(FileServingApp.new).start
