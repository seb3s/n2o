
// WebSocket Transport

$ws = {
    heart: true, 
    interval: 4000,
    creator: function(url) { return window.WebSocket ? new window.WebSocket(url) : false; },
    onheartbeat: function() { this.channel.send('PING'); } 
};

// N2O Reliable Connection

$conn = { onopen: nop, onmessage: nop, onclose: nop,
          send:  function(data)   { if (this.port.channel) this.port.channel.send(data); },
          close: function()       { if (this.port.channel) this.port.channel.close(); } };

var ct = 0,
    transports = [ $ws ],
    heartbeat = null,
    reconnectDelay = 1000,
    maxReconnects = 100,
    wsOk = false,
    wsTimeout = null;

function nop() { }
function bullet(url) { $conn.url = url; return $conn; }
function xport() { return maxReconnects <= ct ? false : transports[ct++ % transports.length]; }
function reconnect() { setTimeout(function() { connect(); }, reconnectDelay); }
function next() { $conn.port = xport(); return $conn.port ? connect() : false; }
function connect() {
    $conn.port.channel = $conn.port.creator($conn.url);
    if (!$conn.port.channel) return next();

    if ($conn.port == $ws) {
        wsTimeout = setTimeout(function() {
            if (!wsOk) {
                $conn.port.channel.onclose = nop;
                next();
            }; }, 3000);
    };

    $conn.port.channel.onmessage = function(e) { 
        if (e.data == 'PONG') wsOk = true;
        $conn.onmessage(e);
    };
    $conn.port.channel.onopen = function() {
        console.log('WebSocket onopen called');
        clearTimeout(wsTimeout);
        $conn.port.onheartbeat(); //send at least one ping immediatly to validate websocket
        if ($conn.port.heart) heartbeat = setInterval(function(){$conn.port.onheartbeat();}, $conn.port.interval);
        $conn.onopen();
    };
    $conn.port.channel.onclose = function() {
        console.log('WebSocket onclose called');
        clearTimeout(wsTimeout);
        clearInterval(heartbeat);
        if (wsOk) {
            $conn.onclose();
            reconnect();
        } else {
            next();
        };
    };
    return $conn; }
