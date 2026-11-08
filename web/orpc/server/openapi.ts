import { OpenAPIGenerator } from "@orpc/openapi";
import { ZodToJsonSchemaConverter } from "@orpc/zod/zod4";

import { router } from "./router";

export async function generateOpenAPIDocument() {
  const generator = new OpenAPIGenerator({
    schemaConverters: [new ZodToJsonSchemaConverter()],
  });

  return generator.generate(router, {
    info: {
      title: "cmux API",
      version: "0.1.0",
    },
    servers: [
      {
        url: "/api/v1",
      },
    ],
  });
}
