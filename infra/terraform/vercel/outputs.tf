output "project_id" {
  description = "Vercel Project ID"
  value       = vercel_project.web.id
}

output "production_domain" {
  description = "本番カスタムドメイン"
  value       = vercel_project_domain.production.domain
}
