/**
 * index.js — Vault + MongoDB Dynamic Credentials Demo
 *
 * Uses the Vault Lambda Extension (proxy mode) to obtain short-lived MongoDB
 * credentials from Vault's database secrets engine, then writes and reads a
 * document to confirm end-to-end access.
 *
 * Flow: Extension authenticates to Vault via AWS IAM → receives token →
 *       proxies requests from this handler → Vault issues dynamic creds →
 *       handler connects to MongoDB and performs read/write demo.
 *
 * Environment variables (set by lambda.tf):
 *   VAULT_ADDR          — Local proxy address (http://127.0.0.1:8200)
 *   VAULT_DB_CREDS_PATH — Vault path for dynamic MongoDB credentials
 *   MONGODB_HOST        — EC2 private IP running MongoDB
 *   MONGODB_PORT        — MongoDB port (default: 27017)
 *   MONGODB_DATABASE    — Target database name (default: mongoDB_demo)
 *
 * Runtime: Node.js 22.x  |  Dependencies: mongodb ^6.8.0
 */
'use strict';

const { MongoClient } = require('mongodb');

/**
 * Lambda handler — invoked on a schedule (default: every 5 minutes) and also
 * manually via `aws lambda invoke`.
 *
 * @param {object} event   - EventBridge scheduled event or manual invocation payload
 * @param {object} context - Lambda context (provides awsRequestId for the demo document)
 * @returns {object} Summary of the demo run including the dynamic username and counts
 */
exports.handler = async function handler(event, context) {
  // Read configuration from environment variables injected by Terraform.
  // VAULT_ADDR points at the local proxy (127.0.0.1:8200), not the real Vault
  // server — the extension intercepts requests and adds the auth token.
  const vaultProxyAddr = process.env.VAULT_ADDR          || 'http://127.0.0.1:8200';
  const dbCredsPath    = process.env.VAULT_DB_CREDS_PATH || 'database/creds/lambda-mongo-role';
  const mongoHost      = process.env.MONGODB_HOST;
  const mongoPort      = process.env.MONGODB_PORT        || '27017';
  const mongoDatabase  = process.env.MONGODB_DATABASE    || 'mongoDB_demo';

  if (!mongoHost) {
    throw new Error('MONGODB_HOST environment variable is not set');
  }

  // ── Step 1: Obtain dynamic MongoDB credentials from Vault ─────────────────
  //
  // The Vault Lambda Extension proxy listens on vaultProxyAddr.  This GET
  // request is intercepted by the extension, which adds the X-Vault-Token
  // header it obtained during its AWS IAM auth handshake, then forwards the
  // request to the real Vault server.
  //
  // Vault's database secrets engine responds by calling MongoDB (as vault_admin)
  // to CREATE a new temporary user, then returns the credentials in the
  // response body.  The user exists only until its TTL (1 hour) expires.
  const credsUrl = `${vaultProxyAddr}/v1/${dbCredsPath}`;
  console.log(`[INFO] Requesting credentials from Vault  proxy: GET ${credsUrl}`);

  const credsResponse = await fetch(credsUrl);

  if (!credsResponse.ok) {
    const body = await credsResponse.text();
    throw new Error(
      `Vault credential request failed: HTTP ${credsResponse.status} — ${body}`
    );
  }

  const vaultSecret               = await credsResponse.json();
  const { username, password }    = vaultSecret.data;
  const leaseDuration             = vaultSecret.lease_duration;

  console.log(`[INFO] Dynamic credential issued  — user: ${username}, lease: ${leaseDuration}s`);

  // ── Step 2: Connect to MongoDB with the dynamic credentials ───────────────
  //
  // Dynamic users are created in MongoDB's 'admin' authentication database
  // with a role grant on 'mongoDB_demo', so authSource=admin is required.
  // The credentials are embedded in the URI using encodeURIComponent to safely
  // handle any special characters Vault might generate in the password.
  const mongoUri = `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${mongoHost}:${mongoPort}/admin`;

  const client = new MongoClient(mongoUri, {
    serverSelectionTimeoutMS: 10_000,  // fail fast if MongoDB is unreachable
    connectTimeoutMS:         10_000,
    directConnection:         true,    // single-node — skip replica set discovery
  });

  try {
    await client.connect();
    console.log('[INFO] Connected to MongoDB');

    const collection = client.db(mongoDatabase).collection('events');

    // ── Step 3: Write a document to mongoDB_demo.events ─────────────────────
    //
    // Each invocation writes a timestamped record that includes the Vault
    // dynamic username so demo observers can confirm a new credential was
    // issued for each Lambda run.
    const doc = {
      timestamp:     new Date().toISOString(),
      message:       'Vault Lambda Extension + MongoDB dynamic credentials demo',
      requestId:     context.awsRequestId,
      vaultUser:     username,
      leaseDuration: leaseDuration,
      source:        'vault-demo-lambda',
    };

    const { insertedId } = await collection.insertOne(doc);
    console.log(`[INFO] Wrote document — _id: ${insertedId}`);

    // ── Step 4: Read the document back ───────────────────────────────────────
    //
    // Confirms that the dynamic user has read access, not just write access,
    // and that the document was durably persisted before we close the connection.
    const readBack = await collection.findOne({ _id: insertedId });
    if (!readBack) {
      throw new Error('Read-back verification failed — document not found after insert');
    }
    console.log(`[INFO] Read-back verified — ${JSON.stringify(readBack)}`);

    const totalDocs = await collection.countDocuments();
    console.log(`[INFO] Total documents in ${mongoDatabase}.events: ${totalDocs}`);

    // ── Step 5: Return a summary ─────────────────────────────────────────────
    const result = {
      success:                    true,
      timestamp:                  doc.timestamp,
      vaultDynamicUser:           username,
      credentialLeaseDurationSec: leaseDuration,
      insertedId:                 insertedId.toString(),
      readBackVerified:           true,
      totalDocumentsInCollection: totalDocs,
    };

    console.log(`[INFO] Demo complete — ${JSON.stringify(result)}`);
    return result;

  } finally {
    // Always close the connection — dynamic credentials have a short TTL and
    // creating a new MongoClient per invocation is acceptable at this scale.
    await client.close();
    console.log('[INFO] MongoDB connection closed');
  }
};
