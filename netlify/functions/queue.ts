import type { Handler, HandlerEvent } from '@netlify/functions'
import { createClient } from '@supabase/supabase-js'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Content-Type': 'application/json',
}

const json = (body: unknown, status = 200) => ({
  statusCode: status,
  headers: CORS,
  body: JSON.stringify(body),
})

const getAdmin = () => createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!
)

const SERVICES: Record<string, { duration: number; price: number }> = {
  coupe:       { duration: 20, price: 1500 },
  barbe:       { duration: 15, price: 1000 },
  coupe_barbe: { duration: 35, price: 2500 },
}

export const handler: Handler = async (event: HandlerEvent) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS, body: '' }

  const supabase = getAdmin()
  const today = new Date().toISOString().split('T')[0]

  // GET
  if (event.httpMethod === 'GET') {
    const salonSlug = event.queryStringParameters?.salon
    if (!salonSlug) return json({ error: 'salon requis' }, 400)

    const { data: salon } = await supabase
      .from('salons').select('id, name, plan').eq('slug', salonSlug).single()
    if (!salon) return json({ error: 'Salon introuvable' }, 404)

    const { data: queue } = await supabase
      .from('queue_entries').select('*')
      .eq('salon_id', salon.id).eq('date', today)
      .in('status', ['waiting', 'called', 'serving'])
      .order('position', { ascending: true })

    return json({ queue: queue ?? [], salon })
  }

  // POST
  if (event.httpMethod === 'POST') {
    let body: any
    try { body = JSON.parse(event.body ?? '{}') } catch { return json({ error: 'Body invalide' }, 400) }

    const { salonSlug, clientName, clientPhone, serviceType = 'coupe' } = body
    if (!salonSlug || !clientName) return json({ error: 'salonSlug et clientName requis' }, 400)

    const { data: salon } = await supabase
      .from('salons').select('id, name').eq('slug', salonSlug).single()
    if (!salon) return json({ error: 'Salon introuvable' }, 404)

    const { count } = await supabase
      .from('queue_entries').select('*', { count: 'exact', head: true })
      .eq('salon_id', salon.id).eq('date', today).eq('status', 'waiting')

    const position = (count ?? 0) + 1
    const svc = SERVICES[serviceType] ?? SERVICES.coupe

    const { data: entry, error } = await supabase
      .from('queue_entries').insert({
        salon_id: salon.id,
        client_name: clientName,
        client_phone: clientPhone ?? null,
        position,
        status: 'waiting',
        service_type: serviceType,
        price: svc.price,
        date: today,
      }).select().single()

    if (error) return json({ error: error.message }, 500)
    return json({ entry, position, waitMin: position * svc.duration }, 201)
  }

  // PATCH
  if (event.httpMethod === 'PATCH') {
    const id = event.queryStringParameters?.id
    if (!id) return json({ error: 'id requis' }, 400)
    let body: any
    try { body = JSON.parse(event.body ?? '{}') } catch { return json({ error: 'Body invalide' }, 400) }
    const { error } = await supabase.from('queue_entries').update({ status: body.status }).eq('id', id)
    if (error) return json({ error: error.message }, 500)
    return json({ success: true })
  }

  // DELETE
  if (event.httpMethod === 'DELETE') {
    const id = event.queryStringParameters?.id
    if (!id) return json({ error: 'id requis' }, 400)
    await supabase.from('queue_entries').delete().eq('id', id)
    return json({ success: true })
  }

  return json({ error: 'Méthode non supportée' }, 405)
}