use Cro::HTTP2::ConnectionState;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::HTTP::Exception;
use Cro;
use HTTP::HPACK;

# HTTP/2 stream
enum State <header-init header-c data>;

my class Stream {
    has Int $.sid;
    has State $.state is rw;
    has Promise $.cancellation;
    has $.message;
    has Bool $.stream-end is rw;
    has Supplier $.body;
    has Buf $.headers is rw;
}

role Cro::HTTP2::GeneralParser does Cro::ConnectionState[Cro::HTTP2::ConnectionState] {
    has $!pseudo-headers;
    has $.enable-push = False;
    has Supplier $!go-away-supplier .= new;
    # Emits the highest stream number that is still allowed to be processed.
    has Supply $.go-away-supply = $!go-away-supplier.Supply;

    method transformer(Supply:D $in, Cro::HTTP2::ConnectionState :$connection-state!) {
        supply {
            my $curr-sid = 0;
            my %streams;
            my ($breakable, $break) = (True, $curr-sid);
            my %push-promises-for-stream;
            my %push-promises-by-promised-id;
            my $decoder = HTTP::HPACK::Decoder.new;

            sub emit-response($sid, $message) {
                with %push-promises-by-promised-id{$sid}:delete {
                    .set-response($message);
                }
                else {
                    emit $message;
                }
            }

            whenever $connection-state.push-promise.Supply { emit $_ }
            whenever $connection-state.settings.Supply {
                when Cro::HTTP2::Frame::Settings {
                    with .settings.first(*.key == 1) {
                        $decoder.set-dynamic-table-limit(.value);
                    }
                    with .settings.first(*.key == 2) {
                        $!enable-push = .value != 0;
                    }
                    with .settings.first(*.key == 4) {
                        $connection-state.remote-window-change.emit: Cro::HTTP2::ConnectionState::WindowInitial.new(initial => .value);
                    }
                }
            }

            whenever $in {
                if !$breakable {
                    if $_ !~~ Cro::HTTP2::Frame::Continuation
                    || $break != .stream-identifier {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }
                }

                when Cro::HTTP2::Frame::Data {
                    my $stream = %streams{.stream-identifier};
                    if $stream {
                        self!check-data($stream, .stream-identifier, $curr-sid);
                        $stream.body.emit: .data;
                        if .end-stream {
                            $stream.body.done;
                        }
                    }
                }
                when Cro::HTTP2::Frame::Headers {
                    unless %streams{.stream-identifier}:exists {
                        $curr-sid = .stream-identifier;
                        my $body = Supplier::Preserving.new;
                        my $cancellation = Promise.new;
                        %streams{$curr-sid} = Stream.new(
                            sid => $curr-sid,
                            state => header-init,
                            :$cancellation,
                            message => self!get-message($curr-sid, .connection, $cancellation),
                            stream-end => .end-stream,
                            :$body,
                            headers => Buf.new);
                        %streams{$curr-sid}.message.set-body-byte-stream($body.Supply);
                        my $response = %streams{$curr-sid}.message;
                        my $response-to-cancel = $response;
                        whenever $cancellation {
                            if $response === $response-to-cancel {
                                $connection-state.stream-reset.emit: $curr-sid;
                                my $exception = X::Cro::HTTP::Client::Timeout.new(phase => 'body', uri => $response.request.target);
                                my $stream = %streams{$curr-sid}:delete;
                                $stream.body.quit($exception);
                            }
                        }
                    }

                    my $stream = %streams{.stream-identifier};
                    my $message = $stream.message;

                    # Process push promises targeting this response.
                    if $message ~~ Cro::HTTP::Response {
                        if $!enable-push {
                            my @promises = @(
                                %push-promises-for-stream{.stream-identifier}:delete // []
                            );
                            $message.add-push-promise($_) for @promises;
                        }
                        $message.close-push-promises;
                    }

                    if .end-headers {
                        self!set-headers($decoder, $message, .headers);
                        if .end-stream {
                            # Message is complete without body
                            if self!message-full($message) {
                                $stream.body.done;
                                emit-response(.stream-identifier, $message);
                            } else {
                                die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                            }
                        } else {
                            $stream.state = data;
                            emit-response(.stream-identifier, $stream.message);
                        }
                    }
                    else {
                        $stream.headers ~= .headers;
                        # No meaning in lock if we're locked already
                        ($breakable, $break) = (False, .stream-identifier) if $breakable;
                        $stream.body.done if .end-stream;
                        $stream.state = header-c;
                    }
                }
                when Cro::HTTP2::Frame::Priority {
                }
                when Cro::HTTP2::Frame::RstStream {
                    with %push-promises-by-promised-id{.stream-identifier}:delete {
                        .cancel-response();
                    }
                    with %streams{.stream-identifier}:delete {
                        if .message {
                            with .body {
                                .quit('Stream reset');
                            }
                        }
                    } else {
                        die 'Stream reset by the server';
                    }
                    %push-promises-for-stream{.stream-identifier}:delete;
                }
                when Cro::HTTP2::Frame::PushPromise {
                    my @headers = $decoder.decode-headers(Buf.new: .headers);
                    my $pp = Cro::HTTP::PushPromise.new(
                        http2-stream-id => .promised-sid,
                        target => @headers.grep({.name eq ':path'})[0].value,
                        http-version => '2.0',
                        :method<GET>);
                    %push-promises-by-promised-id{.promised-sid} = $pp;
                    my @real-headers = @headers.grep({ not .name eq any <:method :scheme :authority :path :status> });
                    for @real-headers { $pp.append-header(.name => .value) }
                    push %push-promises-for-stream{.stream-identifier}, $pp;
                }
                when Cro::HTTP2::Frame::GoAway {
                    $!go-away-supplier.emit: .last-sid;
                    for %push-promises-by-promised-id.kv -> $k, $v {
                        if $k > .last-sid {
                            %push-promises-by-promised-id{$k}:delete;
                            $v.cancel-response();
                        }
                    }
                    for %streams.kv -> $k, $v {
                        if $k > .last-sid {
                            %streams{$k}:delete;
                            $v.cancel-response();
                        }
                    }
                    %push-promises-for-stream{.stream-identifier}:delete;
                }
                when Cro::HTTP2::Frame::WindowUpdate {
                    $connection-state.remote-window-change.emit: Cro::HTTP2::ConnectionState::WindowAdd.new:
                        stream-identifier => .stream-identifier,
                        increment => .increment;
                }
                when Cro::HTTP2::Frame::Continuation {
                    if .stream-identifier > $curr-sid
                    || %streams{.stream-identifier}.state !~~ header-c {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR)
                    }
                    my $message = %streams{.stream-identifier}.message;

                    if .end-headers {
                        ($breakable, $break) = (True, 0);
                        my $headers = %streams{.stream-identifier}.headers ~ .headers;
                        self!set-headers($decoder, $message, $headers);
                        %streams{.stream-identifier}.headers = Buf.new;
                        if %streams{.stream-identifier}.stream-end {
                            if self!message-full($message) {
                                emit-response(.stream-identifier, $message);
                            } else {
                                die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                            }
                        } else {
                            %streams{.stream-identifier}.state = data;
                            emit-response(.stream-identifier, $message);
                        }
                    } else {
                        %streams{.stream-identifier}.headers ~= .headers;
                    }
                }
                LAST done;
            }
        }
    }

    method !set-headers($decoder, $message, $headers) {
        my @headers = $decoder.decode-headers($headers);
        for @headers {
            last if self!message-full($message);
            if .name eq ':status' && $message ~~ Cro::HTTP::Response {
                $message.status = .value.Int unless $message.status;
            } elsif .name eq ':method' && $message ~~ Cro::HTTP::Request {
                $message.method = .value unless $message.method;
            } elsif .name eq ':path' && $message ~~ Cro::HTTP::Request {
                $message.target = .value unless $message.target;
            } elsif .name eq ':authority' && $message ~~ Cro::HTTP::Request {
                $message.append-header('Host' => .value);
            }
        }
        my @real-headers = @headers.grep({ not .name eq any (@$!pseudo-headers) });
        for @real-headers { $message.append-header(.name => .value) };
    }
}
