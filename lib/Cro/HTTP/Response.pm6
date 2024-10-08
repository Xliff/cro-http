use Cro::BodyParserSelector;
use Cro::BodySerializerSelector;
use Cro::HTTP::Cookie;
use Cro::HTTP::BodyParserSelectors;
use Cro::HTTP::BodySerializerSelectors;
use Cro::HTTP::Message;
use Cro::HTTP::Request;
use Cro::HTTP::PushPromise;

my constant %reason-phrases = {
    100 => "Continue",
    101 => "Switching Protocols",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Time-out",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Large",
    415 => "Unsupported Media Type",
    416 => "Requested range not satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Time-out",
    505 => "HTTP Version not supported"
};

#| Exception thrown when one tries to cancel a HTTP response (that is, downloading
#| the body of it), but it is not a cancellable response (probably because it is a
#| response being produced on the server side, rather than from the client).
class X::Cro::HTTP::Response::NotCancellable is Exception {
    method message() {
        "This HTTP response cannot be cancelled (this feature is only available in the HTTP client)"
    }
}

#| A HTTP response. In a client context, this is the response resulting from a
#| HTTP request. In a server context, it is the response being produced to send
#| back to the client.
class Cro::HTTP::Response does Cro::HTTP::Message {
    subset StatusCode of Int where { 100 <= $_ <= 599 }

    #| The HTTP request that this is a response to
    has Cro::HTTP::Request $.request is rw;

    #| The Cro::Router::RequestHandler used
    has $.handler-used is rw;

    #| The HTTP status code of the response
    has StatusCode $.status is rw;

    #| An object deciding how the response body is parsed; used in a client
    #| context
    has Cro::BodyParserSelector $.body-parser-selector is rw =
        Cro::HTTP::BodyParserSelector::ResponseDefault;

    #| An object deciding how the response body is serialized; used in a server
    #| context
    has Cro::BodySerializerSelector $.body-serializer-selector is rw =
        Cro::HTTP::BodySerializerSelector::ResponseDefault;

    has $!cancellation-vow is built;
    has $!push-promises = Supplier::Preserving.new;

    #| The HTTP response as a string, including the response line and any
    #| headers; in HTTP/1.1, this is what shall be sent over the network,
    #| while in other HTTP versions it is just informative
    multi method Str(Cro::HTTP::Response:D:) {
        my $status = $!status // (self.has-body ?? 200 !! 204);
        my $reason = %reason-phrases{$status} // 'Unknown';
        my $headers = self!headers-str();
        my $ver = self.http-version // '1.1';
        $ver = '1.1' if $ver eq '2.0';
        "HTTP/$ver $status $reason\r\n$headers\r\n"
    }

    method trace-output(--> Str) {
        "HTTP Response\n" ~ self.Str.trim.subst("\r\n", "\n", :g).indent(2)
    }

    #| Add a Set-cookie header to the response
    method set-cookie($name, $value, *%options) {
        my $cookie-line = Cro::HTTP::Cookie.new(:$name, :$value, |%options).to-set-cookie;
        my $is-dup = so self.headers.map({ .name.lc eq 'set-cookie' && .value.starts-with("$name=") }).any;
        die "Cookie with name '$name' is already set" if $is-dup;
        self.append-header('Set-Cookie', $cookie-line);
    }

    #| Get a Cro::HTTP::Cookie instance for each cookie that is set by the
    #| response
    method cookies() {
        self.headers.grep({ .name.lc eq 'set-cookie' }).map({ Cro::HTTP::Cookie.from-set-cookie: .value });
    }

    method get-response-phrase() {
        "Server responded with $!status {%reason-phrases{$!status} // 'Unknown'}";
    }

    #| Adds a push promise to the HTTP response
    method add-push-promise(Cro::HTTP::PushPromise $pp --> Nil) {
        $!push-promises.emit: $pp;
    }

    #| Gets a Supply of push promises that have been sent on the request; on a
    #| HTTP/1.1 request, this is always a done Supply
    method push-promises(--> Supply) {
        ($!http-version // '') eq '2.0'
                ?? $!push-promises.Supply
                !! supply { done };
    }

    #| Indicate that there will be no further push promises sent with this
    #| response
    method close-push-promises() {
        $!push-promises.done;
    }

    #| If download of the response body is still ongoing, cancel it. This may close the
    #| underlying connection or just reset the stream, depending on HTTP version.
    method cancel(--> Nil) {
        with $!cancellation-vow {
            try .keep(True); # Cope with duplicate cancel
        }
        else {
            die X::Cro::HTTP::Response::NotCancellable.new;
        }
    }

    method error-hint() {
        "Request: $!request.method() $!request.uri()"
    }
}
