import type { Metadata } from 'next'
export const metadata: Metadata = { title: "Sama Rang", description: "File d'attente digitale" }
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr">
      <body style={{ margin: 0, background: '#0D0D0D' }}>{children}</body>
    </html>
  )
}