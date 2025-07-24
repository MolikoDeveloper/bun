import { expect, test } from "bun:test";
import { bunEnv, bunExe, tempDirWithFiles } from "harness";
import { join } from "path";

const dir = tempDirWithFiles("htmlbundle", {
  "index.html": "<!DOCTYPE html><html><body>Hello HTML</body></html>",
});

const html = (await import(join(dir, "index.html"))).default;

test("fetch routes HTMLBundle", async () => {
  using server = Bun.serve({
    port: 0,
    routes: {
      "/": html,
    },
  });

  const res = await fetch(server.url);
  expect(await res.text()).toContain("Hello HTML");

  const missing = await fetch(`${server.url}/missing`);
  expect(missing.status).toBe(404); // Esto depende de cómo Bun maneja rutas faltantes
});

test("fetch Response(HTMLBundle)", async () => {
  using server = Bun.serve({
    port: 0,
    routes: {
      "/": new Response(html),
    },
  });

  const res = await fetch(server.url);
  expect(await res.text()).toContain("Hello HTML");
  const missing = await fetch(`${server.url}/missing`);
  expect(missing.status).toBe(404);
});

test("fetch async () => Response(HTMLBundle)", async () => {
  using server = Bun.serve({
    port: 0,
    routes: {
      "/": async () => {
        await Bun.sleep(1000);
        return new Response(html);
      },
    },
  });

  const res = await fetch(server.url);
  const text = await res.text();
  expect(text).toContain("Hello HTML");
  const missing = await fetch(`${server.url}/missing`);
  expect(missing.status).toBe(404);
});

test("fetch async () => Response(HTMLBundle) with headers", async () => {
  using server = Bun.serve({
    port: 0,
    routes: {
      "/": async () => {
        return new Response(html, { status: 401, headers: { "X-Test": "true" } });
      },
    },
  });

  const res = await fetch(server.url);
  expect(res.status).toBe(401);
  expect(res.headers.get("x-test")).toBe("true");
  const text = await res.text();
  expect(text).toContain("Hello HTML");
});

test("fetch () => Response(HTMLBundle)", async () => {
  using server = Bun.serve({
    port: 0,
    routes: {
      "/": () => new Response(html),
    },
  });

  const res = await fetch(server.url);
  const text = await res.text();
  expect(text).toContain("Hello HTML");
  const missing = await fetch(`${server.url}/missing`);
  expect(missing.status).toBe(404);
});

test("warns when Response(HTMLBundle) returned from fetch without route", async () => {
  const dir2 = tempDirWithFiles("htmlbundle-warning", {
    "index.html": "<!DOCTYPE html><html><body>Hello HTML</body></html>",
    "server.ts": `import html from "./index.html";
const server = Bun.serve({
  port: 0,
  development: true,
  fetch() {
    return new Response(html);
  },
});
process.send?.(server.url.toString());`,
  });

  const { promise, resolve } = Promise.withResolvers<string>();
  await using proc = Bun.spawn({
    cwd: dir2,
    cmd: [bunExe(), "server.ts"],
    env: bunEnv,
    stderr: "pipe",
    ipc(message) {
      if (typeof message === "string") resolve(message);
    },
  });

  const url = await promise;
  await fetch(url);
  proc.kill();
  await proc.exited;
  const stderr = await proc.stderr.text();
  expect(stderr).toContain("HMR disabled: register HTMLBundle in `routes` to enable dev server.");
});
