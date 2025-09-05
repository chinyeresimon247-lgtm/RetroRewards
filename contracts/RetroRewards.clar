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

(define-constant TIER-BRONZE u1)
(define-constant TIER-SILVER u2)
(define-constant TIER-GOLD u3)
(define-constant TIER-PLATINUM u4)

(define-constant BRONZE-THRESHOLD u1000)
(define-constant SILVER-THRESHOLD u5000)
(define-constant GOLD-THRESHOLD u25000)
(define-constant PLATINUM-THRESHOLD u100000)

;; data vars
(define-data-var last-token-id uint u0)
(define-data-var contract-uri (string-ascii 256) "")
(define-data-var snapshot-active bool false)
(define-data-var current-snapshot-id uint u0)

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

;; public functions

;; Register a new project that can create snapshots
(define-public (register-project (name (string-ascii 100)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
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
    ((snapshot-id (+ (var-get current-snapshot-id) u1))
     (end-block (+ block-height duration-blocks)))
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
    (var-set current-snapshot-id snapshot-id)
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
    (asserts! 
      (is-some (map-get? registered-projects tx-sender)) 
      ERR-UNAUTHORIZED)
    (ok (map-set user-activity {user: user, criteria-type: criteria-type}
      {score: (+ (get score current-data) score), last-updated: block-height}))
  )
)

;; Claim retroactive rewards based on snapshot
(define-public (claim-rewards (snapshot-id uint))
  (let 
    ((snapshot-data (unwrap! (map-get? snapshots snapshot-id) ERR-INVALID-SNAPSHOT))
     (user-score-data (map-get? user-activity 
        {user: tx-sender, criteria-type: (get criteria-type snapshot-data)}))
     (user-score (default-to u0 (get score (default-to {score: u0, last-updated: u0} user-score-data))))
     (tier (calculate-tier user-score))
     (token-id (+ (var-get last-token-id) u1)))
    
    ;; Check if snapshot is still active
    (asserts! (get active snapshot-data) ERR-INVALID-SNAPSHOT)
    (asserts! (<= block-height (get end-block snapshot-data)) ERR-INVALID-SNAPSHOT)
    
    ;; Check if user hasn't already claimed
    (asserts! 
      (not (default-to false 
        (get claimed (default-to {claimed: false, tier: u0, token-id: u0} 
          (map-get? claimed-rewards {user: tx-sender, snapshot-id: snapshot-id})))))
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
      (merge snapshot-data {rewards-minted: (+ (get rewards-minted snapshot-data) u1)}))
    
    ;; Update governance weights
    (update-governance-weight tx-sender token-id tier)
    
    ;; Update last token ID
    (var-set last-token-id token-id)
    
    ;; Mint loyalty tokens based on tier
    (try! (ft-mint? loyalty-token (* tier u100) tx-sender))
    
    (ok token-id)
  )
)

;; Transfer NFT with governance weight update
(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  (let 
    ((token-owner (unwrap! (nft-get-owner? loyalty-nft token-id) ERR-TOKEN-NOT-FOUND))
     (token-data (unwrap! (map-get? token-metadata token-id) ERR-TOKEN-NOT-FOUND)))
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
    (ok (map-set cross-protocol-scores tx-sender
      {protocols: (unwrap! (as-max-len? (append (get protocols current-data) protocol) u20) ERR-INVALID-SNAPSHOT),
       total-score: (+ (get total-score current-data) score)}))
  )
)