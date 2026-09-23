# Odoo master data for the Muster GmbH demo.
#
# Runs inside `odoo shell` from the odoo-init service on every
# `docker compose up`. Every step checks the current state first, so
# re-running it changes nothing.
#
# `env` is provided by odoo shell.
# ruff: noqa: F821

import logging

_log = logging.getLogger("muster.setup")


def ensure_company():
    company = env.ref("base.main_company")
    eur = env.ref("base.EUR")
    if not eur.active:
        eur.active = True

    vals = {
        "name": "Muster GmbH",
        "street": "Musterstraße 1",
        "zip": "20095",
        "city": "Hamburg",
        "country_id": env.ref("base.de").id,
        "email": "info@muster-gmbh.example",
        "phone": "+49 40 1234567",
        "website": "https://muster-gmbh.example",
    }
    changed = {k: v for k, v in vals.items() if (company[k].id if hasattr(company[k], "id") else company[k]) != v}
    if changed:
        company.write(changed)
        _log.info("company updated: %s", sorted(changed))
    return company


def ensure_german_chart(company):
    # SKR03 brings EUR as company currency and the German VAT taxes (19 % / 7 %).
    if company.chart_template == "de_skr03":
        return
    if env["account.move"].search_count([("company_id", "=", company.id)]):
        _log.warning("company has journal entries - not replacing chart %s", company.chart_template)
        return
    env["account.chart.template"].try_loading("de_skr03", company=company, install_demo=False)
    _log.info("loaded chart of accounts de_skr03")


def ensure_eur_pricelists(company):
    # Sales orders take their currency from the pricelist. The default pricelist
    # was created in USD before the company switched to EUR.
    eur = env.ref("base.EUR")
    pricelists = env["product.pricelist"].with_context(active_test=False).search(
        [("currency_id", "!=", eur.id), ("company_id", "in", [company.id, False])]
    )
    if pricelists:
        pricelists.write({"currency_id": eur.id})
        _log.info("pricelists switched to EUR: %s", pricelists.mapped("name"))


def ensure_product(company, default_code, name, sale_ok, purchase_ok):
    product = env["product.product"].with_context(active_test=False).search(
        [("default_code", "=", default_code)], limit=1
    )
    if product:
        return product

    tax_domain = [("company_id", "=", company.id), ("amount", "=", 19), ("price_include", "=", False)]
    sale_tax = env["account.tax"].search(tax_domain + [("type_tax_use", "=", "sale")], limit=1)
    purchase_tax = env["account.tax"].search(tax_domain + [("type_tax_use", "=", "purchase")], limit=1)

    product = env["product.product"].create({
        "name": name,
        "default_code": default_code,
        "type": "service",
        "sale_ok": sale_ok,
        "purchase_ok": purchase_ok,
        "list_price": 0.0,
        "taxes_id": [(6, 0, sale_tax.ids)],
        "supplier_taxes_id": [(6, 0, purchase_tax.ids)],
    })
    _log.info("created product %s", default_code)
    return product


company = ensure_company()
ensure_german_chart(company)
ensure_eur_pricelists(company)
# WF-03: one order line per won opportunity, price = opportunity amount
ensure_product(company, "CRM-DEAL", "Wholesale order (from CRM)", sale_ok=True, purchase_ok=False)
env.cr.commit()
print("odoo-setup: ok")
