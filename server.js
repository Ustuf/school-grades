// Локальный сервер для сайта. Отдаёт ТОЛЬКО index.html (в папке лежит .env с секретами).
// Запуск: node server.js   (адрес: http://localhost:3000, порт можно задать через PORT)

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 3000;
const PAGE = path.join(__dirname, 'index.html');

http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (req.method !== 'GET' || (url !== '/' && url !== '/index.html')) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('Not found');
  }
  fs.readFile(PAGE, (err, html) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('Не удалось прочитать index.html');
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(html);
  });
}).listen(PORT, () => console.log(`Сайт: http://localhost:${PORT}`));
