require "spec_helper.rb"

describe ConservationStatus do
  elastic_models( Observation )

  it { is_expected.to belong_to :taxon }
  it { is_expected.to belong_to :user }
  it { is_expected.to belong_to :place }
  it { is_expected.to belong_to :source }

  it { is_expected.to validate_presence_of :status }
  it { is_expected.to validate_presence_of :iucn }
  it { is_expected.to validate_inclusion_of(:iucn).in_array Taxon::IUCN_STATUS_VALUES.values }

  describe ConservationStatus, "creation" do
    let(:species) { Taxon.make!( rank: Taxon::SPECIES ) }

    it "should obscure observations of taxon" do
      o = Observation.make!( taxon: species, latitude: 1, longitude: 1 )
      expect( o ).not_to be_coordinates_obscured
      cs = without_delay { ConservationStatus.make!( taxon: species ) }
      species.reload
      expect( species ).to be_threatened
      o.reload
      expect( o ).to be_coordinates_obscured
    end

    it "should obscure observations of a taxon in place" do
      p = make_place_with_geom
      o = Observation.make!( taxon: species, latitude: p.latitude, longitude: p.longitude )
      expect( o ).not_to be_coordinates_obscured
      cs = without_delay {ConservationStatus.make!( taxon: species, place: p ) }
      o.reload
      expect( o ).to be_coordinates_obscured
    end

    it "should not obscure observations of taxon outside place" do
      p = make_place_with_geom
      o = Observation.make!( taxon: species, latitude: -1*p.latitude, longitude: p.longitude )
      expect( o ).not_to be_coordinates_obscured
      cs = without_delay { ConservationStatus.make!( taxon: species, place: p ) }
      o.reload
      expect( o ).not_to be_coordinates_obscured
    end

    it "should have geoprivacy obscured by default" do
      expect( ConservationStatus.make!.geoprivacy ).to eq Observation::OBSCURED
    end

    it "should not allow blank string geoprivacy" do
      expect( ConservationStatus.make!(geoprivacy: '').geoprivacy ).to be_nil
    end

    it "should normalize case for geoprivacy" do
      expect( ConservationStatus.make!( geoprivacy: "Obscured" ).geoprivacy ).to eq Observation::OBSCURED
      expect( ConservationStatus.make!( geoprivacy: "PRIVATE" ).geoprivacy ).to eq Observation::PRIVATE
    end

    it "should reassess observations of taxon if obscuring" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      Delayed::Job.delete_all
      stamp = Time.now
      cs = ConservationStatus.make!( taxon: species )
      jobs = Delayed::Job.where("created_at >= ?", stamp)
      expect(jobs.select{|j| j.handler =~ /reassess_coordinates_for_observations_of/m}).not_to be_blank
    end

    it "should not reassess observations of taxon if open and global" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      Delayed::Job.delete_all
      stamp = Time.now
      cs = ConservationStatus.make!( taxon: species, geoprivacy: Observation::OPEN )
      expect( cs.geoprivacy ).to eq Observation::OPEN
      expect( cs.place_id ).to be_nil
      jobs = Delayed::Job.where( "created_at >= ?", stamp )
      expect( jobs.select{ |j| j.handler =~ /reassess_coordinates_for_observations_of/m } ).to be_blank
    end

    it "should not reassess observations of taxon if geoprivacy nil and global" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      Delayed::Job.delete_all
      stamp = Time.now
      cs = ConservationStatus.make!( taxon: species, geoprivacy: nil )
      expect( cs.geoprivacy ).to be_blank
      expect( cs.place_id ).to be_nil
      jobs = Delayed::Job.where( "created_at >= ?", stamp )
      expect( jobs.select{ |j| j.handler =~ /reassess_coordinates_for_observations_of/m } ).to be_blank
    end
  end

  describe ConservationStatus, "saving" do
    it "should should set taxon conservation_status" do
      t = Taxon.make!
      expect(t.conservation_status).to be_blank
      cs = without_delay {ConservationStatus.make!(:taxon => t)}
      expect(cs.iucn).not_to be_blank
      t.reload
      expect(t.conservation_status).to eq(cs.iucn)
    end

    it "should nilify taxon conservation_status if no other global statuses" do
      cs = without_delay {ConservationStatus.make!}
      t = cs.taxon
      expect(t.conservation_status).not_to be_blank
      without_delay {cs.update(:iucn => Taxon::IUCN_LEAST_CONCERN)}
      t.reload
      expect(t.conservation_status).to be < Taxon::IUCN_NEAR_THREATENED
    end

    it "should should not set taxon conservation_status if not the highest status" do
      t = Taxon.make!
      cs1 = without_delay {ConservationStatus.make!(:iucn => Taxon::IUCN_ENDANGERED, :taxon => t, :authority => "foo")}
      cs2 = without_delay {ConservationStatus.make!(:iucn => Taxon::IUCN_LEAST_CONCERN, :taxon => t, :authority => "bar")}
      t.reload
      expect(t.conservation_status).to eq(cs1.iucn)
    end

    it "should should not set taxon conservation_status if not global" do
      t = Taxon.make!
      p = make_place_with_geom
      cs = ConservationStatus.make!(:taxon => t, :place => p)
      t.reload
      expect(t.conservation_status).to be_blank
    end
  end

  describe ConservationStatus, "deletion" do
    it "should reassess observations of taxon" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      cs = without_delay { ConservationStatus.make!( taxon: species ) }
      o = Observation.make!( taxon: species, :latitude => 1, :longitude => 1)
      expect( o ).to be_coordinates_obscured
      cs.destroy
      Delayed::Worker.new.work_off
      species.reload
      expect( species ).not_to be_threatened
      o.reload
      expect( o ).not_to be_coordinates_obscured
    end

    it "should not reassess observations of taxon if open and global" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      cs = without_delay { ConservationStatus.make!( taxon: species, geoprivacy: "Open" ) }
      expect( cs.geoprivacy ).to eq Observation::OPEN
      expect( cs.place_id ).to be_nil
      Delayed::Job.delete_all
      stamp = Time.now
      cs.destroy
      jobs = Delayed::Job.where( "created_at >= ?", stamp )
      expect( jobs.select{ |j| j.handler =~ /reassess_coordinates_for_observations_of/m } ).to be_blank
    end

    it "should not reassess observations of taxon if geoprivacy nil and global" do
      species = Taxon.make!( rank: Taxon::SPECIES )
      cs = without_delay { ConservationStatus.make!( taxon: species, geoprivacy: nil ) }
      expect( cs.geoprivacy ).to be_blank
      expect( cs.place_id ).to be_nil
      Delayed::Job.delete_all
      stamp = Time.now
      cs.destroy
      jobs = Delayed::Job.where( "created_at >= ?", stamp )
      expect( jobs.select{ |j| j.handler =~ /reassess_coordinates_for_observations_of/m } ).to be_blank
    end
  end

  describe ConservationStatus, "updating geoprivacy" do
    let(:species) { Taxon.make!( rank: Taxon::SPECIES ) }
    let(:cs) { ConservationStatus.make!( taxon: species ) }

    it "should obscure observations of taxon" do
      o = Observation.make!( taxon: cs.taxon, latitude: 1, longitude: 1 )
      expect( o ).to be_coordinates_obscured
      without_delay { cs.update( geoprivacy: Observation::PRIVATE ) }
      o.reload
      expect( o.latitude ).to be_blank
    end

    it "should unobscure observations of taxon" do
      o = Observation.make!( taxon: cs.taxon, latitude: 1, longitude: 1 )
      expect( o ).to be_coordinates_obscured
      cs.update( geoprivacy: Observation::PRIVATE )
      Delayed::Worker.new.work_off
      o.reload
      expect( o.latitude ).to be_blank
      cs.update( geoprivacy: Observation::OPEN )
      Delayed::Worker.new.work_off
      o.reload
      expect( o.latitude ).not_to be_blank
      expect( o.private_latitude ).to be_blank
    end

    it "should obscure but not hide coordinates when geoprivacy changes from private to obscured" do
      test_cs = ConservationStatus.make!( taxon: Taxon.make!( rank: Taxon::SPECIES ), geoprivacy: Observation::PRIVATE )
      o = Observation.make!( taxon: test_cs.taxon, latitude: 1, longitude: 1 )
      expect( o ).to be_coordinates_private
      expect( o.latitude ).to be_blank
      test_cs.update( geoprivacy: Observation::OBSCURED )
      Delayed::Worker.new.work_off
      o.reload
      expect( o ).to be_coordinates_obscured
      expect( o.latitude ).not_to be_blank
      expect( o.private_latitude ).to eq 1
    end

    it "should change geom for observations of taxon" do
      o = Observation.make!( taxon: cs.taxon, latitude: 1, longitude: 1 )
      lat = o.latitude
      geom_lat = o.geom.y
      cs.update( geoprivacy: Observation::OPEN )
      expect( cs.taxon.conservation_statuses.count ).to eq 1
      Delayed::Worker.new.work_off
      o.reload
      expect( o.latitude.to_f ).not_to eq lat.to_f
      expect( o.geom.y ).not_to eq geom_lat
    end

    it "should obscure observations of taxon in place" do
      p = make_place_with_geom
      o = Observation.make!( taxon: cs.taxon, latitude: p.latitude, longitude: p.longitude)
      expect( o ).to be_coordinates_obscured
      without_delay { cs.update( geoprivacy: Observation::PRIVATE ) }
      o.reload
      expect( o.latitude ).to be_blank
    end

    it "should not obscure observations of taxon outside place" do
      p = make_place_with_geom
      o = Observation.make!( taxon: cs.taxon, latitude: -1*p.latitude, longitude: p.longitude )
      expect( o ).to be_coordinates_obscured
      without_delay { cs.update( geoprivacy: Observation::PRIVATE, place: p ) }
      o.reload
      expect( o.latitude ).not_to be_blank
    end

    it "should update the public_positional_accuracy in the observations index when unobscured" do
      o = Observation.make!( taxon: cs.taxon, latitude: 1, longitude: 1 )
      expect( o.public_positional_accuracy ).to be > 10
      es_o = Observation.elastic_search( where: { id: o.id } ).results[0]
      expect( es_o.public_positional_accuracy ).to be > 10
      cs.update( geoprivacy: Observation::OPEN )
      Delayed::Worker.new.work_off
      o.reload
      expect( o.public_positional_accuracy ).to be_nil
      es_o = Observation.elastic_search( where: { id: o.id } ).results[0]
      expect( es_o.public_positional_accuracy ).to be_nil
    end
  end

  describe ConservationStatus, "updating place" do
    let(:old_place) { make_place_with_geom }
    let(:new_place) { make_place_with_geom( wkt: "MULTIPOLYGON(((0 0,0 -1,-1 -1,-1 0,0 0)))" ) }
    let(:taxon) { Taxon.make!(:species) }
    it "should reassess observations in the new place" do
      cs = without_delay do
        ConservationStatus.make!( taxon: taxon, place: old_place )
      end
      o = Observation.make!(
          latitude: new_place.latitude,
          longitude: new_place.longitude,
          taxon: cs.taxon
      )
      expect( o ).not_to be_coordinates_obscured
      cs.update( place: new_place )
      Delayed::Worker.new.work_off
      o.reload
      expect( o ).to be_coordinates_obscured
    end
    it "should reassess observations in the old place" do
      cs = without_delay do
        ConservationStatus.make!( taxon: taxon, place: old_place )
      end
      o = without_delay do
        Observation.make!(
            latitude: old_place.latitude,
            longitude: old_place.longitude,
            taxon: cs.taxon
        )
      end
      expect( o ).to be_coordinates_obscured
      cs.update( place: new_place )
      Delayed::Worker.new.work_off
      o.reload
      expect( o ).not_to be_coordinates_obscured
    end
    it "should reassess all observations if place added" do
      cs = without_delay { ConservationStatus.make!( taxon: taxon ) }
      taxon.reload
      o = Observation.make!( taxon: cs.taxon, latitude: -3, longitude: -3 )
      expect( o ).to be_coordinates_obscured
      cs.update( place: new_place )
      Delayed::Worker.new.work_off
      o.reload
      expect( o ).not_to be_coordinates_obscured
    end
    it "should reassess all observations if place removed" do
      cs = without_delay { ConservationStatus.make!( taxon: taxon, place: old_place ) }
      o = Observation.make!(
          taxon: cs.taxon,
          latitude: -3,
          longitude: -3
      )
      expect( o ).not_to be_coordinates_obscured
      cs.update( place: nil )
      Delayed::Worker.new.work_off
      o.reload
      expect( o ).to be_coordinates_obscured
    end
  end
end
