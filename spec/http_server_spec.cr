require "./spec_helper"
require "../src/http_server"
require "json"

# These tests exist because the previous attempt at replacing HTTP::Server
# shipped a parser bug where Content-Length came back as 0 on
# header-order/casing variations the test rig didn't cover. The bug was
# silent: the body slice was empty, the JSON parser produced an
# all-default request, the vectorizer happily emitted a zero vector,
# IVF returned "0 frauds", and we answered `approved: true`. No
# exception, no log, just wrong.
#
# Goal of this spec file: lock the HTTP parser down before depending on
# it. Cover Content-Length parsing across header order, casing,
# whitespace, and HTTP version, and end-to-end-validate the full
# envelope path against the canonical JsonParser fixtures.
describe RinhaDeBackend::HttpServer do
  describe ".parse_request" do
    it "parses a minimal POST with Content-Length and returns the exact body slice" do
      body = %({"hello":"world"})
      req = "POST /fraud-score HTTP/1.1\r\n" \
            "Host: api1:9999\r\n" \
            "Content-Length: #{body.bytesize}\r\n" \
            "\r\n" + body
      method, path, parsed_body, _close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!

      String.new(method).should eq("POST")
      String.new(path).should eq("/fraud-score")
      String.new(parsed_body).should eq(body)
    end

    it "treats Content-Length as case-insensitive" do
      body = %({"a":1})
      [
        "Content-Length",
        "content-length",
        "CONTENT-LENGTH",
        "CoNtEnT-LeNgTh",
      ].each do |name|
        req = "POST /fraud-score HTTP/1.1\r\n" \
              "Host: api1\r\n" \
              "#{name}: #{body.bytesize}\r\n" \
              "\r\n" + body
        _, _, parsed_body, _close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
        String.new(parsed_body).should eq(body)
      end
    end

    it "tolerates extra OWS around the Content-Length value" do
      body = %({"a":1})
      req = "POST /fraud-score HTTP/1.1\r\n" \
            "Host: api1\r\n" \
            "Content-Length:    #{body.bytesize}   \r\n" \
            "\r\n" + body
      _, _, parsed_body, _close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
      String.new(parsed_body).should eq(body)
    end

    it "is independent of header order (Content-Length anywhere in the block)" do
      body = %({"a":1})
      [
        "Content-Length: #{body.bytesize}\r\nHost: api1\r\nUser-Agent: nginx\r\n",
        "Host: api1\r\nContent-Length: #{body.bytesize}\r\nUser-Agent: nginx\r\n",
        "Host: api1\r\nUser-Agent: nginx\r\nContent-Length: #{body.bytesize}\r\n",
      ].each do |headers|
        req = "POST /fraud-score HTTP/1.1\r\n" + headers + "\r\n" + body
        _, _, parsed_body, _close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
        String.new(parsed_body).should eq(body)
      end
    end

    it "honours `Connection: close` (case-insensitive)" do
      body = %({"a":1})
      ["close", "Close", "CLOSE", " close "].each do |val|
        req = "POST /fraud-score HTTP/1.1\r\n" \
              "Host: api1\r\n" \
              "Content-Length: #{body.bytesize}\r\n" \
              "Connection: #{val}\r\n" \
              "\r\n" + body
        _, _, _, conn_close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
        conn_close.should be_true
      end
    end

    it "honours `Connection: keep-alive` on HTTP/1.0 (overrides default close)" do
      body = %({"a":1})
      req = "POST /fraud-score HTTP/1.0\r\n" \
            "Host: api1\r\n" \
            "Content-Length: #{body.bytesize}\r\n" \
            "Connection: keep-alive\r\n" \
            "\r\n" + body
      _, _, _, conn_close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
      conn_close.should be_false
    end

    it "defaults to keep-alive on HTTP/1.1 when no Connection header is present" do
      body = %({"a":1})
      req = "POST /fraud-score HTTP/1.1\r\n" \
            "Host: api1\r\n" \
            "Content-Length: #{body.bytesize}\r\n" \
            "\r\n" + body
      _, _, _, conn_close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
      conn_close.should be_false
    end

    it "defaults to close on HTTP/1.0 when no Connection header is present" do
      body = %({"a":1})
      req = "POST /fraud-score HTTP/1.0\r\n" \
            "Host: api1\r\n" \
            "Content-Length: #{body.bytesize}\r\n" \
            "\r\n" + body
      _, _, _, conn_close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
      conn_close.should be_true
    end

    it "parses a GET /ready with no body" do
      req = "GET /ready HTTP/1.1\r\nHost: api1\r\n\r\n"
      method, path, body, _close = RinhaDeBackend::HttpServer.parse_request(req.to_slice).not_nil!
      String.new(method).should eq("GET")
      String.new(path).should eq("/ready")
      body.size.should eq(0)
    end

    it "returns nil on partial input (no CRLF terminator)" do
      req = "POST /fraud-score HTTP/1.1\r\nHost: api1\r\nContent-Length: 5"
      RinhaDeBackend::HttpServer.parse_request(req.to_slice).should be_nil
    end

    it "returns nil when total length exceeds buffer (declared body extends past slice end)" do
      # Content-Length says 9999 bytes, but the slice only contains the
      # headers + a tiny body. parse_request should refuse rather than
      # return a truncated body slice (which is exactly the silent-zero
      # bug we're guarding against).
      req = "POST /fraud-score HTTP/1.1\r\n" \
            "Host: api1\r\n" \
            "Content-Length: 9999\r\n" \
            "\r\nshort"
      RinhaDeBackend::HttpServer.parse_request(req.to_slice).should be_nil
    end
  end

  describe ".parse_content_length" do
    it "parses plain decimal" do
      v = "1234"
      RinhaDeBackend::HttpServer.parse_content_length(v.to_unsafe, v.bytesize).should eq(1234)
    end

    it "skips leading OWS" do
      v = "   42"
      RinhaDeBackend::HttpServer.parse_content_length(v.to_unsafe, v.bytesize).should eq(42)
    end

    it "stops at the first non-digit (trailing whitespace, garbage, etc.)" do
      v = "42  "
      RinhaDeBackend::HttpServer.parse_content_length(v.to_unsafe, v.bytesize).should eq(42)
    end

    it "returns 0 for empty input" do
      v = ""
      RinhaDeBackend::HttpServer.parse_content_length(v.to_unsafe, v.bytesize).should eq(0)
    end
  end

  describe "end-to-end against the JsonParser fixtures" do
    # Wraps each fixture in a complete HTTP/1.1 envelope, runs it
    # through HttpServer.parse_request, and feeds the resulting body
    # slice into the same JsonParser path the hot loop uses. The 14-dim
    # vector must match what the fixture-only spec already validates.
    mcc_risk   = RinhaDeBackend::MccRisk.new
    vectorizer = RinhaDeBackend::Vectorizer.new(mcc_risk)

    fixtures = JSON.parse(File.read("resources/example-payloads.json")).as_a

    fixtures.each_with_index do |fixture, idx|
      payload = fixture.to_json
      id      = fixture["id"].as_s

      it "matches the canonical vector for fixture ##{idx} (#{id}) end-to-end" do
        envelope = "POST /fraud-score HTTP/1.1\r\n" \
                   "Host: api1\r\n" \
                   "Content-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\n" \
                   "\r\n" + payload

        method, path, body, _close = RinhaDeBackend::HttpServer.parse_request(envelope.to_slice).not_nil!
        String.new(method).should eq("POST")
        String.new(path).should eq("/fraud-score")
        body.size.should eq(payload.bytesize)

        parsed = RinhaDeBackend::JsonParser.parse(body)
        vec_fast = vectorizer.vectorize(body, parsed)

        canon = RinhaDeBackend::FraudScoreRequest.from_json(payload)
        vec_canon = vectorizer.vectorize(canon)

        14.times do |i|
          vec_fast[i].should be_close(vec_canon[i], 1e-5_f32)
        end
      end
    end
  end
end
