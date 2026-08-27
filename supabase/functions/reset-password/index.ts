import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders,
  });
}

function normalizeEmail(value: unknown) {
  return String(value ?? "").trim().toLowerCase();
}

function normalizeCas(value: unknown) {
  return String(value ?? "").trim();
}

function validEncryptedCas(value: string) {
  // Le CAS est déjà chiffré par la page avec le même alphabet que le portail.
  // On n'accepte que l'alphabet attendu pour éviter des entrées arbitraires.
  return /^[A-Z](?:-[A-Z])*(?:\/[A-Z](?:-[A-Z])*)*$/.test(value);
}

function validPassword(value: unknown): value is string {
  return typeof value === "string" && value.length >= 8 && value.length <= 128;
}

async function verifier(email: string, codeSocial: string) {
  if (!email || !codeSocial || !validEncryptedCas(codeSocial)) return null;

  const { data, error } = await supabaseAdmin
    .from("citoyens")
    .select("id,email,code_social_encrypte")
    .eq("email", email)
    .maybeSingle();

  if (error || !data) return null;
  if (data.code_social_encrypte !== codeSocial) return null;

  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);

  try {
    const body = await req.json();
    const action = body?.action;
    const email = normalizeEmail(body?.email);
    const codeSocial = normalizeCas(body?.code_social);

    if (action !== "verify" && action !== "reset") {
      return json({ error: "Requête invalide." }, 400);
    }

    const citoyen = await verifier(email, codeSocial);

    // Même message pour compte inexistant et CAS incorrect afin de limiter
    // la divulgation d'informations sur les comptes.
    if (!citoyen) {
      return json({ error: "Courriel ou Code d’Assurance Social invalide." }, 400);
    }

    if (action === "verify") {
      return json({ verified: true });
    }

    const password = body?.password;
    if (!validPassword(password)) {
      return json({ error: "Le mot de passe doit contenir entre 8 et 128 caractères." }, 400);
    }

    const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
      citoyen.id,
      { password }
    );

    if (updateError) {
      console.error("Erreur updateUserById:", updateError);
      return json({ error: "Impossible de modifier le mot de passe." }, 500);
    }

    return json({ success: true });
  } catch (error) {
    console.error("Erreur reset-password:", error);
    return json({ error: "Erreur interne." }, 500);
  }
});
