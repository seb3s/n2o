
// N2O XHR Fallback

$xhr = { 
    heart: false,
    interval: 4000,
    longpoll : true,
	creator: function(url) {
		$conn.url = xhr_url(url);
        $xhr.channel = { send: xhr_send, close: xhr_close };
        if ($conn.port.heart) heartbeat = setInterval(function(){$conn.port.onheartbeat();}, $conn.port.interval);
        if ($conn.port.longpoll) n2o.next_poll();
        $conn.onopen();
        return $xhr.channel; },
    onheartbeat: function() { this.channel.send('PING'); }
};

transports = [$ws,$xhr];

function xhr_header(request) { request.setRequestHeader('Content-Type','application/x-www-form-urlencoded; charset=utf-8'); }
function xhr_url(url) { return url.replace('ws:', 'http:').replace('wss:', 'https:'); }
function xhr_close() { $conn.onclose(); clearInterval(heartbeat); }
function xhr_send(data) { return xhr('POST',data); }
function xhr_receive(data) { if (data.length != 0) $conn.onmessage({'data':data}); }
function xhr(method,data) {
    var request = new XMLHttpRequest();
    request.open(method,$conn.url,true);
    xhr_header(request);
    request.onload = function() { console.log(request.response); xhr_receive(request.response); };
    request.send(data);
    return true; }


var n2o = (function (n2o) {

function xhr_poll(method, url, data) {
    var request = new XMLHttpRequest();
    request.open(method,url,true);
    request.onload = function() { 
        console.log('Polling: ' + request.response); 
        xhr_receive(request.response); 
        n2o.next_poll();
    };
    request.send(data);
    return true;
};

n2o.next_poll = function() { 
    setTimeout(function(){ xhr_poll('GET', $conn.url.replace('/ws', '/xhrpoll')); }, 50); 
};

return n2o; 
}(n2o || {}));
