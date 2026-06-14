import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

// Served as a GitHub project page → https://nnao45.github.io/nixx/
export default defineConfig({
  site: "https://nnao45.github.io",
  base: "/nixx",
  trailingSlash: "always",
  vite: {
    plugins: [tailwindcss()],
  },
});
