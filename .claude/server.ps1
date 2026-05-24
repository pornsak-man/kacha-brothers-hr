# Minimal HTTP file server for Claude Preview testing
$port = 5180
$root = "C:\Users\porns\kacha-brothers-hr"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Server running on http://localhost:$port/ root=$root"

$mimeMap = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.md'   = 'text/plain; charset=utf-8'
}

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        $relPath = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
        if ($relPath -eq '') { $relPath = 'index.html' }
        $filePath = Join-Path $root $relPath

        Write-Host "$($req.HttpMethod) $($req.Url.AbsolutePath) -> $filePath"

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mime = $mimeMap[$ext]; if (-not $mime) { $mime = 'application/octet-stream' }
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $res.ContentType = $mime
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $res.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("404: $relPath")
            $res.OutputStream.Write($msg, 0, $msg.Length)
        }
        $res.Close()
    } catch {
        Write-Host "ERR: $_"
    }
}
