import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: "Sama Rang — File d'attente digitale",
  description: "Rejoignez la file d'attente de votre salon en un scan",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
      </head>
      <body style={{ margin: 0, padding: 0, background: '#0D0D0D' }}>
        {children}
      </body>
    </html>
  )
}