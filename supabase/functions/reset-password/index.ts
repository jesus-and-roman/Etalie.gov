import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

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
  return /^[A-Z](?:-[A-Z])*(?:\/[A-Z](?:-[A-Z])*)*$/.test(value);
}

function validPassword(value: unknown): value is string {
  return typeof value === "string" &&
    value.length >= 8 &&
    value.length <= 128;
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  throw new Error("Variables Supabase manquantes.");
}

const supabaseAdmin = createClient(
  SUPABASE_URL,
  SERVICE_ROLE_KEY,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

async function verifier(email: string, codeSocial: string) {
  if (!email || !codeSocial || !validEncryptedCas(codeSocial)) {
    return null;
  }

  const { data, error } = await supabaseAdmin
    .from("citoyens")
    .select("id,email,code_social_encrypte")
    .eq("email", email)
    .maybeSingle();

  if (error) {
    console.error("Erreur recherche citoyen:", error);
    return null;
  }

  if (!data) {
    return null;
  }

  if (data.code_social_encrypte !== codeSocial) {
    return null;
  }

  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  if (req.method !== "POST") {
    return json(
      { error: "Méthode non autorisée." },
      405
    );
  }

  try {
    const body = await req.json();

    const action = body?.action;
    const email = normalizeEmail(body?.email);
    const codeSocial = normalizeCas(body?.code_social);

    if (action !== "verify" && action !== "reset") {
      return json(
        { error: "Requête invalide." },
        400
      );
    }

    const citoyen = await verifier(
      email,
      codeSocial
    );

    if (!citoyen) {
      return json(
        {
          error:
            "Courriel ou Code d’Assurance Social invalide."
        },
        400
      );
    }

    /*
     * ÉTAPE 1 :
     * Vérification de l'identité uniquement.
     */
    if (action === "verify") {
      return json({
        verified: true
      });
    }

    /*
     * ÉTAPE 2 :
     * Changement du mot de passe.
     */

    const password = body?.password;

    if (!validPassword(password)) {
      return json(
        {
          error:
            "Le mot de passe doit contenir entre 8 et 128 caractères."
        },
        400
      );
    }

    /*
     * citoyen.id correspond à auth.users.id
     * puisque l'inscription utilise auth.uid()
     * comme identifiant du citoyen.
     */
    const {
      error: updateError
    } = await supabaseAdmin.auth.admin.updateUserById(
      citoyen.id,
      {
        password: password
      }
    );

    if (updateError) {
      console.error(
        "Erreur Supabase Auth:",
        updateError
      );

      return json(
        {
          error:
            "Impossible de modifier le mot de passe."
        },
        500
      );
    }

    return json({
      success: true
    });

  } catch (error) {
    console.error(
      "Erreur reset-password:",
      error
    );

    return json(
      {
        error: "Erreur interne."
      },
      500
    );
  }
});
