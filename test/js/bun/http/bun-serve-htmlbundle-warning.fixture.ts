import html from "./index.html";

const server = Bun.serve({
  port: 0,
  development: true,
  fetch() {
    return new Response(html);
  },
});

process.send?.(server.url.toString());
