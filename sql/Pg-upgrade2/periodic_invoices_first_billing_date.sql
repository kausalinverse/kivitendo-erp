-- @tag: periodic_invoices_first_billing_date
-- @description: Wiederkehrende Rechnungen: Feld für erstes Rechnungsdatum
-- @depends: periodic_invoices
-- @charset: utf-8
ALTER TABLE periodic_invoices_configs ADD COLUMN first_billing_date DATE;
