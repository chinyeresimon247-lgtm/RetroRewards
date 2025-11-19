;; title: RetroRewards - Retroactive Loyalty Mining
;; version: 1.0.0
;; summary: Retroactively reward past blockchain interactions with tiered loyalty NFTs
;; description: This contract enables projects to analyze on-chain history and mint loyalty tokens
;;              based on historical activity, creating composable loyalty scores across protocols

;; traits
(define-trait nft-trait
  (
    (last-token-id () (response uint uint))
    (get-token-uri (uint) (response (optional (string-ascii 256)) uint))
    (get-owner (uint) (response (optional principal) uint))
    (transfer (uint principal principal) (response bool uint))
  )
)

;; token definitions
(define-non-fungible-token loyalty-nft uint)
(define-fungible-token loyalty-token)

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-TOKEN-OWNER (err u101))
(define-constant ERR-INVALID-TIER (err u102))
(define-constant ERR-ALREADY-CLAIMED (err u103))
(define-constant ERR-INSUFFICIENT-ACTIVITY (err u104))
(define-constant ERR-INVALID-SNAPSHOT (err u105))
(define-constant ERR-TOKEN-NOT-FOUND (err u106))
(define-constant ERR-UNAUTHORIZED (err u107))
(define-constant ERR-CONTRACT-PAUSED (err u108))
(define-constant ERR-RATE-LIMIT-EXCEEDED (err u109))
(define-constant ERR-OVERFLOW (err u110))
(define-constant ERR-INVALID-INPUT (err u111))
(define-constant ERR-UNDERFLOW (err u112))
(define-constant ERR-EMERGENCY-ONLY (err u113))
(define-constant ERR-COOLDOWN-ACTIVE (err u114))
(define-constant ERR-BATCH-TOO-LARGE (err u115))
(define-constant ERR-SNAPSHOT-INACTIVE (err u116))

(define-constant TIER-BRONZE u1)
(define-constant TIER-SILVER u2)
(define-constant TIER-GOLD u3)
(define-constant TIER-PLATINUM u4)

(define-constant BRONZE-THRESHOLD u1000)
(define-constant SILVER-THRESHOLD u5000)
(define-constant GOLD-THRESHOLD u25000)
(define-constant PLATINUM-THRESHOLD u100000)

(define-constant RATE-LIMIT-BLOCKS u10)
(define-constant MAX-OPERATIONS-PER-BLOCK u5)
(define-constant MAX-BATCH-SIZE u10)
(define-constant EMERGENCY-COOLDOWN-BLOCKS u144)
(define-constant MIN-SNAPSHOT-DURATION u100)

;; data vars
(define-data-var last-token-id uint u0)
(define-data-var contract-uri (string-ascii 256) "")
(define-data-var snapshot-active bool false)
(define-data-var current-snapshot-id uint u0)
(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var last-emergency-action uint u0)
(define-data-var total-rewards-claimed uint u0)
(define-data-var total-snapshots-created uint u0)

;; data maps
;; Store user activity scores for different criteria types
(define-map user-activity 
  {user: principal, criteria-type: (string-ascii 50)} 
  {score: uint, last-updated: uint}
)

;; Store claimed status for users per snapshot
(define-map claimed-rewards 
  {user: principal, snapshot-id: uint} 
  {claimed: bool, tier: uint, token-id: uint}
)

;; Store snapshot configurations
(define-map snapshots 
  uint 
  {
    creator: principal,
    criteria-type: (string-ascii 50),
    min-threshold: uint,
    max-rewards: uint,
    rewards-minted: uint,
    active: bool,
    end-block: uint
  }
)

;; Store NFT metadata
(define-map token-metadata 
  uint 
  {
    tier: uint,
    snapshot-id: uint,
    score: uint,
    uri: (string-ascii 256)
  }
)

;; Store governance weights
(define-map governance-weights 
  principal 
  {total-weight: uint, tokens: (list 50 uint)}
)

;; Store project registrations
(define-map registered-projects 
  principal 
  {name: (string-ascii 100), active: bool, snapshots-created: uint}
)

;; Cross-protocol loyalty tracking
(define-map cross-protocol-scores 
  principal 
  {protocols: (list 20 (string-ascii 50)), total-score: uint}
)

(define-map last-operation-block principal uint)
(define-map operations-per-block {user: principal, block: uint} uint)

;; Tier statistics tracking
(define-map tier-statistics uint {bronze: uint, silver: uint, gold: uint, platinum: uint})

;; Snapshot status tracking
(define-map snapshot-status uint bool)

;; Security helper functions
(define-private (check-not-paused)
  (if (var-get contract-paused)
    ERR-CONTRACT-PAUSED
    (ok true)
  )
)

(define-private (safe-add (a uint) (b uint))
  (let ((result (+ a b)))
    (asserts! (>= result a) ERR-OVERFLOW)
    (ok result)
  )
)

(define-private (safe-mul (a uint) (b uint))
  (let ((result (* a b)))
    (asserts! (or (is-eq b u0) (is-eq (/ result b) a)) ERR-OVERFLOW)
    (ok result)
  )
)

(define-private (safe-sub (a uint) (b uint))
  (if (>= a b)
    (ok (- a b))
    ERR-UNDERFLOW
  )
)

(define-private (check-rate-limit (user principal))
  (let (
    (current-block burn-block-height)
    (last-block (default-to u0 (map-get? last-operation-block user)))
    (ops-count (default-to u0 (map-get? operations-per-block {user: user, block: current-block})))
  )
    (asserts! 
      (or 
        (>= (- current-block last-block) RATE-LIMIT-BLOCKS)
        (< ops-count MAX-OPERATIONS-PER-BLOCK)
      )
      ERR-RATE-LIMIT-EXCEEDED
    )
    (map-set last-operation-block user current-block)
    (map-set operations-per-block {user: user, block: current-block} (+ ops-count u1))
    (ok true)
  )
)

(define-private (validate-string-not-empty (str (string-ascii 50)))
  (if (> (len str) u0)
    (ok true)
    ERR-INVALID-INPUT
  )
)

(define-private (check-emergency-cooldown)
  (let ((last-action (var-get last-emergency-action)))
    (asserts! 
      (or 
        (is-eq last-action u0)
        (>= (- burn-block-height last-action) EMERGENCY-COOLDOWN-BLOCKS)
      )
      ERR-COOLDOWN-ACTIVE
    )
    (ok true)
  )
)

(define-private (check-not-emergency)
  (if (var-get emergency-mode)
    ERR-EMERGENCY-ONLY
    (ok true)
  )
)

(define-private (validate-batch-size (size uint))
  (if (and (> size u0) (<= size MAX-BATCH-SIZE))
    (ok true)
    ERR-BATCH-TOO-LARGE
  )
)

(define-private (check-snapshot-active (snapshot-id uint))
  (let ((snapshot-data (unwrap! (map-get? snapshots snapshot-id) ERR-INVALID-SNAPSHOT)))
    (asserts! (get active snapshot-data) ERR-SNAPSHOT-INACTIVE)
    (asserts! (<= burn-block-height (get end-block snapshot-data)) ERR-SNAPSHOT-INACTIVE)
    (ok true)
  )
)

;; public functions

;; Pause/unpause contract (owner only)
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (var-set contract-paused false)
    (ok true)
  )
)

;; Emergency mode controls
(define-public (activate-emergency-mode)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (try! (check-emergency-cooldown))
    (var-set emergency-mode true)
    (var-set last-emergency-action burn-block-height)
    (ok true)
  )
)

(define-public (deactivate-emergency-mode)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (try! (check-emergency-cooldown))
    (var-set emergency-mode false)
    (var-set last-emergency-action burn-block-height)
    (ok true)
  )
)

;; Deactivate/reactivate snapshots
(define-public (deactivate-snapshot (snapshot-id uint))
  (let ((snapshot-data (unwrap! (map-get? snapshots snapshot-id) ERR-INVALID-SNAPSHOT)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (map-set snapshots snapshot-id (merge snapshot-data {active: false}))
    (map-set snapshot-status snapshot-id false)
    (ok true)
  )
)

(define-public (reactivate-snapshot (snapshot-id uint))
  (let ((snapshot-data (unwrap! (map-get? snapshots snapshot-id) ERR-INVALID-SNAPSHOT)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (<= burn-block-height (get end-block snapshot-data)) ERR-SNAPSHOT-INACTIVE)
    (map-set snapshots snapshot-id (merge snapshot-data {active: true}))
    (map-set snapshot-status snapshot-id true)
    (ok true)
  )
)

;; Register a new project that can create snapshots
(define-public (register-project (name (string-ascii 100)))
  (begin
    (try! (check-not-paused))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    (ok (map-set registered-projects tx-sender 
      {name: name, active: true, snapshots-created: u0}))
  )
)

;; Create a new snapshot for retroactive rewards
(define-public (create-snapshot 
    (criteria-type (string-ascii 50))
    (min-threshold uint)
    (max-rewards uint)
    (duration-blocks uint))
  (let 
    ((snapshot-id (unwrap! (safe-add (var-get current-snapshot-id) u1) ERR-OVERFLOW))
     (end-block (unwrap! (safe-add burn-block-height duration-blocks) ERR-OVERFLOW)))
    (try! (check-not-paused))
    (try! (check-not-emergency))
    (try! (check-rate-limit tx-sender))
    (try! (validate-string-not-empty criteria-type))
    (asserts! (> min-threshold u0) ERR-INVALID-INPUT)
    (asserts! (> max-rewards u0) ERR-INVALID-INPUT)
    (asserts! (>= duration-blocks MIN-SNAPSHOT-DURATION) ERR-INVALID-INPUT)
    (asserts! 
      (is-some (map-get? registered-projects tx-sender)) 
      ERR-UNAUTHORIZED)
    (map-set snapshots snapshot-id {
      creator: tx-sender,
      criteria-type: criteria-type,
      min-threshold: min-threshold,
      max-rewards: max-rewards,
      rewards-minted: u0,
      active: true,
      end-block: end-block
    })
    (map-set snapshot-status snapshot-id true)
    (map-set tier-statistics snapshot-id {bronze: u0, silver: u0, gold: u0, platinum: u0})
    (var-set current-snapshot-id snapshot-id)
    (var-set total-snapshots-created (unwrap! (safe-add (var-get total-snapshots-created) u1) ERR-OVERFLOW))
    (ok snapshot-id)
  )
)

;; Submit user activity data (can only be called by registered projects)
(define-public (submit-activity 
    (user principal)
    (criteria-type (string-ascii 50))
    (score uint))
  (let 
    ((current-data (default-to {score: u0, last-updated: u0} 
        (map-get? user-activity {user: user, criteria-type: criteria-type}))))
    (try! (check-not-paused))
    (try! (check-rate-limit tx-sender))
    (try! (validate-string-not-empty criteria-type))
    (asserts! (> score u0) ERR-INVALID-INPUT)
    (asserts! 
      (is-some (map-get? registered-projects tx-sender)) 
      ERR-UNAUTHORIZED)
    (ok (map-set user-activity {user: user, criteria-type: criteria-type}
      {score: (unwrap! (safe-add (get score current-data) score) ERR-OVERFLOW), last-updated: burn-block-height}))
  )
)

;; Claim retroactive rewards based on snapshot
(define-public (claim-rewards (snapshot-id uint))
  (let 
    ((snapshot-data (unwrap! (map-get? snapshots snapshot-id) ERR-INVALID-SNAPSHOT))
     (user-score-data (map-get? user-activity 
        {user: tx-sender, criteria-type: (get criteria-type snapshot-data)}))
     (user-score (match user-score-data data (get score data) u0))
     (tier (calculate-tier user-score))
     (token-id (unwrap! (safe-add (var-get last-token-id) u1) ERR-OVERFLOW)))
    
    (try! (check-not-paused))
    (try! (check-rate-limit tx-sender))
    
    ;; Check if snapshot is still active
    (asserts! (get active snapshot-data) ERR-INVALID-SNAPSHOT)
    (asserts! (<= burn-block-height (get end-block snapshot-data)) ERR-INVALID-SNAPSHOT)
    
    ;; Check if user hasn't already claimed
    (asserts!
      (not (get claimed (default-to {claimed: false, tier: u0, token-id: u0}
        (map-get? claimed-rewards {user: tx-sender, snapshot-id: snapshot-id}))))
      ERR-ALREADY-CLAIMED)
    
    ;; Check if user meets minimum threshold
    (asserts! (>= user-score (get min-threshold snapshot-data)) ERR-INSUFFICIENT-ACTIVITY)
    
    ;; Check if max rewards not exceeded
    (asserts! (< (get rewards-minted snapshot-data) (get max-rewards snapshot-data)) ERR-INVALID-SNAPSHOT)
    
    ;; Mint NFT
    (try! (nft-mint? loyalty-nft token-id tx-sender))
    
    ;; Update token metadata
    (map-set token-metadata token-id {
      tier: tier,
      snapshot-id: snapshot-id,
      score: user-score,
      uri: (generate-token-uri tier)
    })
    
    ;; Mark as claimed
    (map-set claimed-rewards {user: tx-sender, snapshot-id: snapshot-id}
      {claimed: true, tier: tier, token-id: token-id})
    
    ;; Update snapshot rewards count
    (map-set snapshots snapshot-id 
      (merge snapshot-data {rewards-minted: (unwrap! (safe-add (get rewards-minted snapshot-data) u1) ERR-OVERFLOW)}))
    
    ;; Update governance weights
    (update-governance-weight tx-sender token-id tier)
    
    ;; Update tier statistics
    (update-tier-stats snapshot-id tier)
    
    ;; Update last token ID
    (var-set last-token-id token-id)
    
    ;; Update total rewards claimed
    (var-set total-rewards-claimed (unwrap! (safe-add (var-get total-rewards-claimed) u1) ERR-OVERFLOW))
    
    ;; Mint loyalty tokens based on tier
    (try! (ft-mint? loyalty-token (unwrap! (safe-mul tier u100) ERR-OVERFLOW) tx-sender))
    
    (ok token-id)
  )
)

;; Transfer NFT with governance weight update
(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  (let 
    ((token-owner (unwrap! (nft-get-owner? loyalty-nft token-id) ERR-TOKEN-NOT-FOUND))
     (token-data (unwrap! (map-get? token-metadata token-id) ERR-TOKEN-NOT-FOUND)))
    (try! (check-not-paused))
    (asserts! (is-eq tx-sender sender) ERR-NOT-TOKEN-OWNER)
    (asserts! (is-eq sender token-owner) ERR-NOT-TOKEN-OWNER)
    
    ;; Transfer NFT
    (try! (nft-transfer? loyalty-nft token-id sender recipient))
    
    ;; Update governance weights
    (remove-governance-weight sender token-id (get tier token-data))
    (update-governance-weight recipient token-id (get tier token-data))
    
    (ok true)
  )
)

;; Update cross-protocol loyalty score
(define-public (update-cross-protocol-score 
    (protocol (string-ascii 50))
    (score uint))
  (let 
    ((current-data (default-to {protocols: (list), total-score: u0} 
        (map-get? cross-protocol-scores tx-sender))))
    (try! (check-not-paused))
    (try! (validate-string-not-empty protocol))
    (asserts! (> score u0) ERR-INVALID-INPUT)
    (ok (map-set cross-protocol-scores tx-sender
      {protocols: (unwrap! (as-max-len? (append (get protocols current-data) protocol) u20) ERR-INVALID-SNAPSHOT),
       total-score: (unwrap! (safe-add (get total-score current-data) score) ERR-OVERFLOW)}))
  )
)

;; Batch claim rewards for multiple snapshots
(define-public (batch-claim-rewards (snapshot-ids (list 10 uint)))
  (begin
    (try! (check-not-paused))
    (try! (check-not-emergency))
    (try! (validate-batch-size (len snapshot-ids)))
    (ok (map claim-single-reward snapshot-ids))
  )
)

;; Helper for batch claiming
(define-private (claim-single-reward (snapshot-id uint))
  (match (claim-rewards snapshot-id)
    success success
    error u0
  )
)

;; SIP-009 NFT Standard Compliance
(define-read-only (get-last-token-id)
  (ok (var-get last-token-id))
)

(define-read-only (get-token-uri (token-id uint))
  (ok (get uri (default-to 
    {tier: u0, snapshot-id: u0, score: u0, uri: ""} 
    (map-get? token-metadata token-id))))
)

(define-read-only (get-owner (token-id uint))
  (ok (nft-get-owner? loyalty-nft token-id))
)

;; read only functions

;; Get user activity score for specific criteria
(define-read-only (get-user-activity (user principal) (criteria-type (string-ascii 50)))
  (map-get? user-activity {user: user, criteria-type: criteria-type})
)

;; Get snapshot information
(define-read-only (get-snapshot (snapshot-id uint))
  (map-get? snapshots snapshot-id)
)

;; Check if user has claimed rewards for a snapshot
(define-read-only (has-claimed-rewards (user principal) (snapshot-id uint))
  (match (map-get? claimed-rewards {user: user, snapshot-id: snapshot-id})
    data (get claimed data)
    false)
)

;; Get token metadata
(define-read-only (get-token-metadata (token-id uint))
  (map-get? token-metadata token-id)
)

;; Get governance weight for a user
(define-read-only (get-governance-weight (user principal))
  (map-get? governance-weights user)
)

;; Get cross-protocol loyalty score
(define-read-only (get-cross-protocol-score (user principal))
  (map-get? cross-protocol-scores user)
)

;; Check if project is registered
(define-read-only (is-registered-project (project principal))
  (is-some (map-get? registered-projects project))
)

;; Calculate tier based on score
(define-read-only (calculate-tier-view (score uint))
  (calculate-tier score)
)

;; Security read-only functions
(define-read-only (is-contract-paused)
  (var-get contract-paused)
)

(define-read-only (is-emergency-mode)
  (var-get emergency-mode)
)

(define-read-only (get-last-emergency-action)
  (var-get last-emergency-action)
)

(define-read-only (get-last-operation-block (user principal))
  (default-to u0 (map-get? last-operation-block user))
)

(define-read-only (get-snapshot-creator (snapshot-id uint))
  (match (map-get? snapshots snapshot-id)
    snapshot (some (get creator snapshot))
    none
  )
)

;; Statistics read-only functions
(define-read-only (get-total-rewards-claimed)
  (var-get total-rewards-claimed)
)

(define-read-only (get-total-snapshots-created)
  (var-get total-snapshots-created)
)

(define-read-only (get-tier-statistics (snapshot-id uint))
  (map-get? tier-statistics snapshot-id)
)

(define-read-only (get-snapshot-status (snapshot-id uint))
  (default-to false (map-get? snapshot-status snapshot-id))
)

;; private functions

;; Calculate tier based on user score
(define-private (calculate-tier (score uint))
  (if (>= score PLATINUM-THRESHOLD)
    TIER-PLATINUM
    (if (>= score GOLD-THRESHOLD)
      TIER-GOLD
      (if (>= score SILVER-THRESHOLD)
        TIER-SILVER
        TIER-BRONZE
      )
    )
  )
)

;; Generate token URI based on tier
(define-private (generate-token-uri (tier uint))
  (if (is-eq tier TIER-PLATINUM)
    "ipfs://QmPlatinum/metadata.json"
    (if (is-eq tier TIER-GOLD)
      "ipfs://QmGold/metadata.json"
      (if (is-eq tier TIER-SILVER)
        "ipfs://QmSilver/metadata.json"
        "ipfs://QmBronze/metadata.json"
      )
    )
  )
)

;; Update tier statistics for a snapshot
(define-private (update-tier-stats (snapshot-id uint) (tier uint))
  (let ((current-stats (default-to {bronze: u0, silver: u0, gold: u0, platinum: u0} 
          (map-get? tier-statistics snapshot-id))))
    (map-set tier-statistics snapshot-id
      (if (is-eq tier TIER-PLATINUM)
        (merge current-stats {platinum: (+ (get platinum current-stats) u1)})
        (if (is-eq tier TIER-GOLD)
          (merge current-stats {gold: (+ (get gold current-stats) u1)})
          (if (is-eq tier TIER-SILVER)
            (merge current-stats {silver: (+ (get silver current-stats) u1)})
            (merge current-stats {bronze: (+ (get bronze current-stats) u1)})
          )
        )
      )
    )
    true
  )
)

;; Update governance weight when NFT is minted or transferred
(define-private (update-governance-weight (user principal) (token-id uint) (tier uint))
  (let 
    ((current-weight (default-to {total-weight: u0, tokens: (list)} 
        (map-get? governance-weights user)))
     (new-tokens (unwrap-panic (as-max-len? (append (get tokens current-weight) token-id) u50)))
     (tier-weight (unwrap-panic (safe-mul tier u10)))
     (new-total-weight (unwrap-panic (safe-add (get total-weight current-weight) tier-weight))))
    (begin
      (map-set governance-weights user {
        total-weight: new-total-weight,
        tokens: new-tokens
      })
      true
    )
  )
)

;; Remove governance weight when NFT is transferred
(define-private (remove-governance-weight (user principal) (token-id uint) (tier uint))
  (let 
    (
      (current-weight (default-to {total-weight: u0, tokens: (list)} 
        (map-get? governance-weights user)))
      (tier-weight (unwrap-panic (safe-mul tier u10)))
      (new-total-weight (unwrap-panic (safe-sub (get total-weight current-weight) tier-weight)))
    )
    (begin
      (map-set governance-weights user {
        total-weight: new-total-weight,
        tokens: (get tokens current-weight)
      })
      true
    )
  )
)