package SL::SEPA;

use strict;

use POSIX qw(strftime);

use Data::Dumper;
use SL::DBUtils;
use SL::DB::Invoice;
use SL::DB::PurchaseInvoice;
use SL::Locale::String qw(t8);
use DateTime;

sub retrieve_open_invoices {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);
  my $arap     = $params{vc} eq 'customer' ? 'ar'       : 'ap';
  my $vc       = $params{vc} eq 'customer' ? 'customer' : 'vendor';

  my $mandate  = $params{vc} eq 'customer' ? " AND COALESCE(vc.mandator_id, '') <> '' AND vc.mandate_date_of_signature IS NOT NULL " : '';

  # in query: for customers, use payment terms from invoice, for vendors use
  # payment terms from vendor details
  # currently there is no option in vendor invoices for setting payment term,
  # so vendor details are always used

  my $payment_term_type = $params{vc} eq 'customer' ? "${arap}" : 'vc';

  my $query =
    qq|
       SELECT ${arap}.id, ${arap}.invnumber, ${arap}.transdate, ${arap}.${vc}_id as vc_id, ${arap}.amount AS invoice_amount, ${arap}.invoice,
	       (${arap}.transdate + pt.terms_skonto) as skonto_date, (pt.percent_skonto * 100) as percent_skonto,
         (${arap}.amount - (${arap}.amount * pt.percent_skonto)) as amount_less_skonto,
         (${arap}.amount * pt.percent_skonto) as skonto_amount,
         vc.name AS vcname, vc.language_id, ${arap}.duedate as duedate, ${arap}.direct_debit,

         COALESCE(vc.iban, '') <> '' AND COALESCE(vc.bic, '') <> '' ${mandate} AS vc_bank_info_ok,

         ${arap}.amount - ${arap}.paid - COALESCE(open_transfers.amount, 0) AS open_amount

       FROM ${arap}
       LEFT JOIN ${vc} vc ON (${arap}.${vc}_id = vc.id)
       LEFT JOIN (SELECT sei.ap_id, SUM(sei.amount) AS amount
                  FROM sepa_export_items sei
                  LEFT JOIN sepa_export se ON (sei.sepa_export_id = se.id)
                  WHERE NOT se.closed
                    AND (se.vc = '${vc}')
                  GROUP BY sei.ap_id)
         AS open_transfers ON (${arap}.id = open_transfers.ap_id)

       LEFT JOIN payment_terms pt ON (${payment_term_type}.payment_id = pt.id)

       WHERE ${arap}.amount > (COALESCE(open_transfers.amount, 0) + ${arap}.paid)

       ORDER BY lower(vc.name) ASC, lower(${arap}.invnumber) ASC
|;

  my $results = selectall_hashref_query($form, $dbh, $query);

  # add some more data to $results:
  # create drop-down data for payment types and suggest amount to be paid according
  # to open amount or skonto

  foreach my $result ( @$results ) {
    my $invoice = $vc eq 'customer' ? SL::DB::Manager::Invoice->find_by(         id => $result->{id} )
                                    : SL::DB::Manager::PurchaseInvoice->find_by( id => $result->{id} );

    $invoice->get_payment_suggestions;
    $result->{skonto_amount}             = $invoice->skonto_amount;
    $result->{within_skonto_period}      = $invoice->within_skonto_period;
    $result->{invoice_amount_suggestion} = $invoice->{invoice_amount_suggestion};
    $result->{payment_select_options}    = $invoice->{payment_select_options};
  };

  $main::lxdebug->leave_sub();

  return $results;
}

sub create_export {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  Common::check_params(\%params, qw(employee bank_transfers vc));

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;
  my $arap     = $params{vc} eq 'customer' ? 'ar'       : 'ap';
  my $vc       = $params{vc} eq 'customer' ? 'customer' : 'vendor';
  my $ARAP     = uc $arap;

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);

  my ($export_id) = selectfirst_array_query($form, $dbh, qq|SELECT nextval('sepa_export_id_seq')|);
  my $query       =
    qq|INSERT INTO sepa_export (id, employee_id, vc)
       VALUES (?, (SELECT id
                   FROM employee
                   WHERE login = ?), ?)|;
  do_query($form, $dbh, $query, $export_id, $params{employee}, $vc);

  my $q_item_id = qq|SELECT nextval('id')|;
  my $h_item_id = prepare_query($form, $dbh, $q_item_id);
  my $c_mandate = $params{vc} eq 'customer' ? ', vc_mandator_id, vc_mandate_date_of_signature' : '';
  my $p_mandate = $params{vc} eq 'customer' ? ', ?, ?' : '';

  my $q_insert =
    qq|INSERT INTO sepa_export_items (id,          sepa_export_id,           ${arap}_id,  chart_id,
                                      amount,      requested_execution_date, reference,   end_to_end_id,
                                      our_iban,    our_bic,                  vc_iban,     vc_bic,
                                      skonto_amount, payment_type ${c_mandate})
       VALUES                        (?,           ?,                        ?,           ?,
                                      ?,           ?,                        ?,           ?,
                                      ?,           ?,                        ?,           ?,
                                      ?,           ? ${p_mandate})|;
  my $h_insert = prepare_query($form, $dbh, $q_insert);

  my $q_reference =
    qq|SELECT arap.invnumber,
         (SELECT COUNT(at.*)
          FROM acc_trans at
          LEFT JOIN chart c ON (at.chart_id = c.id)
          WHERE (at.trans_id = ?)
            AND (c.link LIKE '%${ARAP}_paid%'))
         +
         (SELECT COUNT(sei.*)
          FROM sepa_export_items sei
          WHERE (sei.ap_id = ?))
         AS num_payments
       FROM ${arap} arap
       WHERE id = ?|;
  my $h_reference = prepare_query($form, $dbh, $q_reference);

  my @now         = localtime;

  foreach my $transfer (@{ $params{bank_transfers} }) {
    if (!$transfer->{reference}) {
      do_statement($form, $h_reference, $q_reference, (conv_i($transfer->{"${arap}_id"})) x 3);

      my ($invnumber, $num_payments) = $h_reference->fetchrow_array();
      $num_payments++;

      $transfer->{reference} = "${invnumber}-${num_payments}";
    }

    $h_item_id->execute();
    my ($item_id)      = $h_item_id->fetchrow_array();

    my $end_to_end_id  = strftime "LXO%Y%m%d%H%M%S", localtime;
    my $item_id_len    = length "$item_id";
    my $num_zeroes     = 35 - $item_id_len - length $end_to_end_id;
    $end_to_end_id    .= '0' x $num_zeroes if (0 < $num_zeroes);
    $end_to_end_id    .= $item_id;
    $end_to_end_id     = substr $end_to_end_id, 0, 35;

    my @values = ($item_id,                          $export_id,
                  conv_i($transfer->{"${arap}_id"}), conv_i($transfer->{chart_id}),
                  $transfer->{amount},               conv_date($transfer->{requested_execution_date}),
                  $transfer->{reference},            $end_to_end_id,
                  map { my $pfx = $_; map { $transfer->{"${pfx}_${_}"} } qw(iban bic) } qw(our vc));
    # save value of skonto_amount and payment_type
    if ( $transfer->{payment_type} eq 'without_skonto' ) {
      push(@values, 0);
    } elsif ($transfer->{payment_type} eq 'difference_as_skonto' ) {
      push(@values, $transfer->{amount});
    } elsif ($transfer->{payment_type} eq 'with_skonto_pt' ) {
      push(@values, $transfer->{skonto_amount});
    } else {
      die "illegal payment_type: " . $transfer->{payment_type} . "\n";
    };
    push(@values, $transfer->{payment_type});

    push @values, $transfer->{vc_mandator_id}, conv_date($transfer->{vc_mandate_date_of_signature}) if $params{vc} eq 'customer';

    do_statement($form, $h_insert, $q_insert, @values);
  }

  $h_insert->finish();
  $h_item_id->finish();

  $dbh->commit() unless ($params{dbh});

  $main::lxdebug->leave_sub();

  return $export_id;
}

sub retrieve_export {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  Common::check_params(\%params, qw(id vc));

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;
  my $vc       = $params{vc} eq 'customer' ? 'customer' : 'vendor';
  my $arap     = $params{vc} eq 'customer' ? 'ar'       : 'ap';

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);

  my ($joins, $columns);

  if ($params{details}) {
    $columns = ', arap.invoice';
    $joins   = "LEFT JOIN ${arap} arap ON (se.${arap}_id = arap.id)";
  }

  my $query =
    qq|SELECT se.*,
         CASE WHEN COALESCE(e.name, '') <> '' THEN e.name ELSE e.login END AS employee
       FROM sepa_export se
       LEFT JOIN employee e ON (se.employee_id = e.id)
       WHERE se.id = ?|;

  my $export = selectfirst_hashref_query($form, $dbh, $query, conv_i($params{id}));

  if ($export->{id}) {
    my ($columns, $joins);

    my $mandator_id = $params{vc} eq 'customer' ? ', mandator_id, mandate_date_of_signature' : '';

    if ($params{details}) {
      $columns = qq|, arap.invnumber, arap.invoice, arap.transdate AS reference_date, vc.name AS vc_name, vc.${vc}number AS vc_number, c.accno AS chart_accno, c.description AS chart_description ${mandator_id}|;
      $joins   = qq|LEFT JOIN ${arap} arap ON (sei.${arap}_id = arap.id)
                    LEFT JOIN ${vc} vc     ON (arap.${vc}_id  = vc.id)
                    LEFT JOIN chart c      ON (sei.chart_id   = c.id)|;
    }

    $query = qq|SELECT sei.*
                  $columns
                FROM sepa_export_items sei
                $joins
                WHERE sei.sepa_export_id = ?|;

    $export->{items} = selectall_hashref_query($form, $dbh, $query, conv_i($params{id}));

  } else {
    $export->{items} = [];
  }

  $main::lxdebug->leave_sub();

  return $export;
}

sub close_export {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  Common::check_params(\%params, qw(id));

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);

  my @ids          = ref $params{id} eq 'ARRAY' ? @{ $params{id} } : ($params{id});
  my $placeholders = join ', ', ('?') x scalar @ids;
  my $query        = qq|UPDATE sepa_export SET closed = TRUE WHERE id IN ($placeholders)|;

  do_query($form, $dbh, $query, map { conv_i($_) } @ids);

  $dbh->commit() unless ($params{dbh});

  $main::lxdebug->leave_sub();
}

sub list_exports {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;
  my $vc       = $params{vc} eq 'customer' ? 'customer' : 'vendor';
  my $arap     = $params{vc} eq 'customer' ? 'ar'       : 'ap';

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);

  my %sort_columns = (
    'id'          => [ 'se.id',                ],
    'export_date' => [ 'se.itime',             ],
    'employee'    => [ 'e.name',      'se.id', ],
    'executed'    => [ 'se.executed', 'se.id', ],
    'closed'      => [ 'se.closed',   'se.id', ],
    );

  my %sort_spec = create_sort_spec('defs' => \%sort_columns, 'default' => 'id', 'column' => $params{sortorder}, 'dir' => $params{sortdir});

  my (@where, @values, @where_sub, @values_sub, %joins_sub);

  my $filter = $params{filter} || { };

  foreach (qw(executed closed)) {
    push @where, $filter->{$_} ? "se.$_" : "NOT se.$_" if (exists $filter->{$_});
  }

  my %operators = ('from' => '>=',
                   'to'   => '<=');

  foreach my $dir (qw(from to)) {
    next unless ($filter->{"export_date_${dir}"});
    push @where,  "se.itime $operators{$dir} ?::date";
    push @values, $filter->{"export_date_${dir}"};
  }

  if ($filter->{invnumber}) {
    push @where_sub,  "arap.invnumber ILIKE ?";
    push @values_sub, '%' . $filter->{invnumber} . '%';
    $joins_sub{$arap} = 1;
  }

  if ($filter->{vc}) {
    push @where_sub,  "vc.name ILIKE ?";
    push @values_sub, '%' . $filter->{vc} . '%';
    $joins_sub{$arap} = 1;
    $joins_sub{vc}    = 1;
  }

  foreach my $type (qw(requested_execution execution)) {
    foreach my $dir (qw(from to)) {
      next unless ($filter->{"${type}_date_${dir}"});
      push @where_sub,  "(items.${type}_date IS NOT NULL) AND (items.${type}_date $operators{$dir} ?)";
      push @values_sub, $filter->{"${type}_date_${_}"};
    }
  }

  if (@where_sub) {
    my $joins_sub  = '';
    $joins_sub    .= " LEFT JOIN ${arap} arap ON (items.${arap}_id = arap.id)" if ($joins_sub{$arap});
    $joins_sub    .= " LEFT JOIN ${vc} vc      ON (arap.${vc}_id   = vc.id)"   if ($joins_sub{vc});

    my $where_sub  = join(' AND ', map { "(${_})" } @where_sub);

    my $query_sub  = qq|se.id IN (SELECT items.sepa_export_id
                                  FROM sepa_export_items items
                                  $joins_sub
                                  WHERE $where_sub)|;

    push @where,  $query_sub;
    push @values, @values_sub;
  }

  push @where,  'se.vc = ?';
  push @values, $vc;

  my $where = @where ? ' WHERE ' . join(' AND ', map { "(${_})" } @where) : '';

  my $query =
    qq|SELECT se.id, se.employee_id, se.executed, se.closed, itime::date AS export_date,
         e.name AS employee
       FROM sepa_export se
       LEFT JOIN (
         SELECT emp.id,
           CASE WHEN COALESCE(emp.name, '') <> '' THEN emp.name ELSE emp.login END AS name
         FROM employee emp
       ) AS e ON (se.employee_id = e.id)
       $where
       ORDER BY $sort_spec{sql}|;

  my $results = selectall_hashref_query($form, $dbh, $query, @values);

  $main::lxdebug->leave_sub();

  return $results;
}

sub post_payment {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  Common::check_params(\%params, qw(items));

  my $myconfig = \%main::myconfig;
  my $form     = $main::form;
  my $vc       = $params{vc} eq 'customer' ? 'customer' : 'vendor';
  my $arap     = $params{vc} eq 'customer' ? 'ar'       : 'ap';
  my $mult     = $params{vc} eq 'customer' ? -1         : 1;
  my $ARAP     = uc $arap;

  my $dbh      = $params{dbh} || $form->get_standard_dbh($myconfig);

  my @items    = ref $params{items} eq 'ARRAY' ? @{ $params{items} } : ($params{items});

  my %handles  = (
    'get_item'       => [ qq|SELECT sei.*
                             FROM sepa_export_items sei
                             WHERE sei.id = ?| ],

    'get_arap'       => [ qq|SELECT at.chart_id
                             FROM acc_trans at
                             LEFT JOIN chart c ON (at.chart_id = c.id)
                             WHERE (trans_id = ?)
                               AND ((c.link LIKE '%:${ARAP}') OR (c.link LIKE '${ARAP}:%') OR (c.link = '${ARAP}'))
                             LIMIT 1| ],

    'add_acc_trans'  => [ qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, gldate,       source, memo, taxkey, tax_id ,                                     chart_link)
                             VALUES                (?,        ?,        ?,      ?,         current_date, ?,      '',   0,      (SELECT id FROM tax WHERE taxkey=0 LIMIT 1), (SELECT link FROM chart WHERE id=?))| ],

    'update_arap'    => [ qq|UPDATE ${arap}
                             SET paid = paid + ?
                             WHERE id = ?| ],

    'finish_item'    => [ qq|UPDATE sepa_export_items
                             SET execution_date = ?, executed = TRUE
                             WHERE id = ?| ],

    'has_unexecuted' => [ qq|SELECT sei1.id
                             FROM sepa_export_items sei1
                             WHERE (sei1.sepa_export_id = (SELECT sei2.sepa_export_id
                                                           FROM sepa_export_items sei2
                                                           WHERE sei2.id = ?))
                               AND NOT COALESCE(sei1.executed, FALSE)
                             LIMIT 1| ],

    'do_close'       => [ qq|UPDATE sepa_export
                             SET executed = TRUE, closed = TRUE
                             WHERE (id = ?)| ],
    );

  map { unshift @{ $_ }, prepare_query($form, $dbh, $_->[0]) } values %handles;

  foreach my $item (@items) {

    my $item_id = conv_i($item->{id});

    # Retrieve the item data belonging to the ID.
    do_statement($form, @{ $handles{get_item} }, $item_id);
    my $orig_item = $handles{get_item}->[0]->fetchrow_hashref();

    next if (!$orig_item);

    # fetch item_id via Rose (same id as orig_item)
    my $sepa_export_item = SL::DB::Manager::SepaExportItem->find_by( id => $item_id);

    my $invoice;

    if ( $sepa_export_item->ar_id ) {
      $invoice = SL::DB::Manager::Invoice->find_by( id => $sepa_export_item->ar_id);
    } elsif ( $sepa_export_item->ap_id ) {
      $invoice = SL::DB::Manager::PurchaseInvoice->find_by( id => $sepa_export_item->ap_id);
    } else {
      die "sepa_export_item needs either ar_id or ap_id\n";
    };

    $invoice->pay_invoice(amount       => $sepa_export_item->amount,
                          payment_type => $sepa_export_item->payment_type,
                          chart_id     => $sepa_export_item->chart_id,
                          source       => $sepa_export_item->reference,
                          transdate    => $item->{execution_date},  # value from user form
                         );

    # Update the item to reflect that it has been posted.
    do_statement($form, @{ $handles{finish_item} }, $item->{execution_date}, $item_id);

    # Check whether or not we can close the export itself if there are no unexecuted items left.
    do_statement($form, @{ $handles{has_unexecuted} }, $item_id);
    my ($has_unexecuted) = $handles{has_unexecuted}->[0]->fetchrow_array();

    if (!$has_unexecuted) {
      do_statement($form, @{ $handles{do_close} }, $orig_item->{sepa_export_id});
    }
  }

  map { $_->[0]->finish() } values %handles;

  $dbh->commit() unless ($params{dbh});

  $main::lxdebug->leave_sub();
}

1;
