# Variable de GitHub Actions para publicar las imágenes

Una sola **variable** (no secret): `FRONTEND_BUILD_ARGS`.

Dónde: repositorio en GitHub → Settings → Secrets and variables → Actions →
pestaña **Variables** → New repository variable.

- Name: `FRONTEND_BUILD_ARGS`
- Value: el bloque de abajo, una clave por línea, sin comillas, sin `export`
  y sin espacios alrededor del `=`.

Los valores se hornean en el bundle del navegador, así que son públicos. No
pongas aquí `CLERK_SECRET_KEY`, `STRIPE_SECRET_KEY` ni contraseñas.

## Valor para copiar y pegar

Sustituye los `<...>` por tus valores (están en `.env.production`).

```
NEXT_PUBLIC_FRONTEND_URL=https://qr.weareadn.dev
NEXT_PUBLIC_API_URL=https://qr.weareadn.dev/api/v1
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=<pk_live_...>
NEXT_PUBLIC_CLERK_JS_URL=/__clerk-js/dist/clerk.browser.min.js
NEXT_PUBLIC_SENTRY_DSN=<https://...@...ingest.sentry.io/...>
NEXT_PUBLIC_SENTRY_ENVIRONMENT=production
NEXT_PUBLIC_GOOGLE_API_KEY=<tu_clave_google>
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY=<price_...>
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL=<price_...>
NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY=<price_...>
NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL=<price_...>
```

## Obligatorias

El workflow falla si falta alguna de estas 9 o está vacía:

`NEXT_PUBLIC_FRONTEND_URL`, `NEXT_PUBLIC_API_URL`,
`NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`, `NEXT_PUBLIC_SENTRY_DSN`,
`NEXT_PUBLIC_GOOGLE_API_KEY`, `NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY`,
`NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL`,
`NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY`,
`NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL`.

## Opcionales (añádelas al bloque si las usas)

```
NEXT_PUBLIC_SHORT_URL_DOMAIN=https://qrco.ly
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY_LEGACY=<price_...>
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL_LEGACY=<price_...>
NEXT_PUBLIC_POSTHOG_KEY=<phc_...>
NEXT_PUBLIC_POSTHOG_HOST=https://eu.i.posthog.com
```

## Alternativa por consola

Con los valores reales ya en un fichero local (fuera del repo):

```bash
gh variable set FRONTEND_BUILD_ARGS -R <owner>/<repo> < mis-build-args.env
gh variable list -R <owner>/<repo>
```

No uses `scripts/docker/ci.env`: lleva valores falsos para la simulación local.

## Placeholders para CI y build de prueba

Valores falsos, solo para comprobar que el workflow y el build pasan (por
ejemplo con `workflow_dispatch`). La imagen resultante **no sirve para
producción**: Clerk, Stripe, Sentry y Google no funcionarán.

```
NEXT_PUBLIC_FRONTEND_URL=http://127.0.0.1:3000
NEXT_PUBLIC_API_URL=http://127.0.0.1:5001/api/v1
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_Y2xlcmsuZXhhbXBsZS5jb20k
NEXT_PUBLIC_CLERK_JS_URL=/__clerk-js/dist/clerk.browser.min.js
NEXT_PUBLIC_SENTRY_DSN=https://ci@sentry.invalid/1
NEXT_PUBLIC_SENTRY_ENVIRONMENT=production
NEXT_PUBLIC_GOOGLE_API_KEY=ci-google-key
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY=price_ci_pro_monthly
NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL=price_ci_pro_annual
NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY=price_ci_addon_monthly
NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL=price_ci_addon_annual
```
